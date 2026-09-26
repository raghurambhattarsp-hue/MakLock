import AppKit
import Combine

/// Monitors app launches and activations to detect when a protected app starts.
final class AppMonitorService: ObservableObject {
    static let shared = AppMonitorService()

    /// Published when a protected app is launched or activated.
    @Published var detectedApp: ProtectedApp?

    /// Callback invoked when a protected app is detected.
    var onProtectedAppDetected: ((ProtectedApp) -> Void)?

    private var cancellables = Set<AnyCancellable>()

    /// Apps that have been authenticated in the current session.
    private var authenticatedApps: Set<String> = []

    /// Bundle IDs that have a pending overlay prompt.
    private var pendingLockBundleIDs: Set<String> = []

    /// Last application reported by NSWorkspace activation notifications.
    private var lastActiveBundleID: String?

    /// Polls normal-window state to detect red-X/window-close.
    private var windowStateTimer: Timer?

    /// Previous normal-window state for authenticated protected apps.
    private var protectedWindowState: [String: Bool] = [:]

    private init() {}

    /// Start monitoring app launches and activations.
    func startMonitoring() {
        let workspace = NSWorkspace.shared

        lastActiveBundleID = workspace.frontmostApplication?.bundleIdentifier

        // Monitor app launches.
        workspace.notificationCenter.publisher(
            for: NSWorkspace.didLaunchApplicationNotification
        )
        .compactMap {
            $0.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
        }
        .sink { [weak self] app in
            self?.handleAppEvent(app)
        }
        .store(in: &cancellables)

        // Monitor app activations.
        workspace.notificationCenter.publisher(
            for: NSWorkspace.didActivateApplicationNotification
        )
        .compactMap {
            $0.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
        }
        .sink { [weak self] app in
            self?.handleAppActivation(app)
        }
        .store(in: &cancellables)

        // Monitor app terminations.
        workspace.notificationCenter.publisher(
            for: NSWorkspace.didTerminateApplicationNotification
        )
        .compactMap {
            $0.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
        }
        .sink { [weak self] app in
            guard let self,
                  let bundleID = app.bundleIdentifier else {
                return
            }

            self.pendingLockBundleIDs.remove(bundleID)
            self.protectedWindowState.removeValue(forKey: bundleID)

            if self.authenticatedApps.contains(bundleID) {
                self.authenticatedApps.remove(bundleID)
                NSLog(
                    "[MakLock] App terminated, auth cleared: %@",
                    bundleID
                )
            }
        }
        .store(in: &cancellables)

        startWindowMonitoring()

        NSLog("[MakLock] App monitor started")

        // Check already-running protected apps.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            [weak self] in
            self?.checkRunningApps()
        }
    }

    /// Handles a real application activation.
    ///
    /// When an authenticated protected app loses focus to another app,
    /// its authentication session is cleared. The next activation will
    /// require authentication again.
    private func handleAppActivation(_ runningApp: NSRunningApplication) {
        guard let bundleID = runningApp.bundleIdentifier else {
            return
        }

        let previousBundleID = lastActiveBundleID
        lastActiveBundleID = bundleID

        if let previousBundleID,
           previousBundleID != bundleID {
            clearAuthenticatedAppAfterSwitch(
                from: previousBundleID
            )
        }

        handleAppEvent(runningApp)
    }

    private func clearAuthenticatedAppAfterSwitch(from bundleID: String) {
        guard authenticatedApps.contains(bundleID) else {
            return
        }

        // Never treat MakLock itself as a protected application switch.
        if bundleID == Bundle.main.bundleIdentifier {
            return
        }

        let settings = Defaults.shared.appSettings
        guard settings.isProtectionEnabled else {
            return
        }

        let isProtected = Defaults.shared.protectedApps.contains {
            $0.bundleIdentifier == bundleID && $0.isEnabled
        }

        guard isProtected else {
            return
        }

        authenticatedApps.remove(bundleID)
        pendingLockBundleIDs.remove(bundleID)

        NSLog(
            "[MakLock] App switch detected, auth cleared: %@",
            bundleID
        )
    }

    // MARK: - Window State Monitoring

    private func startWindowMonitoring() {
        windowStateTimer?.invalidate()

        let timer = Timer(
            timeInterval: 0.5,
            repeats: true
        ) { [weak self] _ in
            self?.checkProtectedAppWindows()
        }

        windowStateTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func checkProtectedAppWindows() {
        let authenticatedBundleIDs = Array(authenticatedApps)
        let workspace = NSWorkspace.shared

        for bundleID in authenticatedBundleIDs {
            guard let app = workspace.runningApplications.first(
                where: { $0.bundleIdentifier == bundleID }
            ) else {
                authenticatedApps.remove(bundleID)
                pendingLockBundleIDs.remove(bundleID)
                protectedWindowState.removeValue(forKey: bundleID)

                NSLog(
                    "[MakLock] Authenticated app disappeared: %@",
                    bundleID
                )

                continue
            }

            let hasWindows = appHasWindows(app)
            let previousState = protectedWindowState[bundleID]

            protectedWindowState[bundleID] = hasWindows

            // Red-X / last-window-close detection.
            if previousState == true && hasWindows == false {
                authenticatedApps.remove(bundleID)
                pendingLockBundleIDs.remove(bundleID)

                NSLog(
                    "[MakLock] Last window closed, auth cleared: %@",
                    bundleID
                )

                continue
            }

            // Fallback for a process that stays alive and gets a window
            // again without producing a useful activation notification.
            if previousState == false,
               hasWindows,
               workspace.frontmostApplication?.bundleIdentifier == bundleID,
               !OverlayWindowService.shared.isShowing {

                handleAppEvent(app)
            }
        }
    }

    /// Scan currently running apps and trigger lock for any protected ones.
    private func checkRunningApps() {
        let protectedList = Defaults.shared.protectedApps
        let settings = Defaults.shared.appSettings

        NSLog(
            "[MakLock] checkRunningApps: %d protected, protection=%@",
            protectedList.count,
            settings.isProtectionEnabled ? "ON" : "OFF"
        )

        guard settings.isProtectionEnabled else {
            return
        }

        let workspace = NSWorkspace.shared

        for runningApp in workspace.runningApplications {
            guard let bundleID = runningApp.bundleIdentifier else {
                continue
            }

            if let protectedApp = protectedList.first(where: {
                $0.bundleIdentifier == bundleID && $0.isEnabled
            }) {
                guard !authenticatedApps.contains(bundleID) else {
                    continue
                }

                guard !pendingLockBundleIDs.contains(bundleID) else {
                    continue
                }

                guard !OverlayWindowService.shared.isShowing else {
                    continue
                }

                NSLog(
                    "[MakLock] Found running protected app: %@ (%@)",
                    protectedApp.name,
                    bundleID
                )

                detectedApp = protectedApp
                onProtectedAppDetected?(protectedApp)

                return
            }
        }
    }

    /// Stop monitoring.
    func stopMonitoring() {
        cancellables.removeAll()
        windowStateTimer?.invalidate()
        windowStateTimer = nil
        protectedWindowState.removeAll()

        NSLog("[MakLock] App monitor stopped")
    }

    /// Mark an app as authenticated.
    func markAuthenticated(_ bundleIdentifier: String) {
        authenticatedApps.insert(bundleIdentifier)
        pendingLockBundleIDs.remove(bundleIdentifier)

        if let app = NSWorkspace.shared.runningApplications.first(
            where: { $0.bundleIdentifier == bundleIdentifier }
        ) {
            protectedWindowState[bundleIdentifier] = appHasWindows(app)
        }

        NSLog(
            "[MakLock] App session authenticated: %@",
            bundleIdentifier
        )
    }

    /// Cancel a pending lock without authenticating the app.
    func cancelPendingLock(for bundleIdentifier: String) {
        pendingLockBundleIDs.remove(bundleIdentifier)

        NSLog(
            "[MakLock] Pending lock cancelled: %@",
            bundleIdentifier
        )
    }

    /// Clear all authentication sessions.
    func clearAllAuthentications() {
        authenticatedApps.removeAll()
        pendingLockBundleIDs.removeAll()
        protectedWindowState.removeAll()

        NSLog("[MakLock] All app sessions cleared")
    }

    /// Clear authentication for a specific app.
    func clearAuthentication(for bundleIdentifier: String) {
        authenticatedApps.remove(bundleIdentifier)
        pendingLockBundleIDs.remove(bundleIdentifier)
        protectedWindowState.removeValue(forKey: bundleIdentifier)
    }

    /// Check if an app is currently authenticated.
    func isAuthenticated(_ bundleIdentifier: String) -> Bool {
        authenticatedApps.contains(bundleIdentifier)
    }

    /// Check if an app has any normal-level windows (layer 0).
    private func appHasWindows(_ app: NSRunningApplication) -> Bool {
        let pid = app.processIdentifier

        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionAll],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return true
        }

        return windowList.contains { info in
            guard let windowPID =
                    info[kCGWindowOwnerPID as String] as? Int32,
                  let windowLayer =
                    info[kCGWindowLayer as String] as? Int else {
                return false
            }

            return windowPID == pid && windowLayer == 0
        }
    }

    private func handleAppEvent(
        _ runningApp: NSRunningApplication
    ) {
        guard let bundleID = runningApp.bundleIdentifier else {
            return
        }

        guard !SafetyManager.isBlacklisted(bundleID) else {
            return
        }

        let protectedApps = Defaults.shared.protectedApps

        guard let protectedApp = protectedApps.first(where: {
            $0.bundleIdentifier == bundleID && $0.isEnabled
        }) else {
            return
        }

        let settings = Defaults.shared.appSettings

        guard settings.isProtectionEnabled else {
            return
        }

        guard !authenticatedApps.contains(bundleID) else {
            return
        }

        guard !OverlayWindowService.shared.isShowing else {
            return
        }

        guard !pendingLockBundleIDs.contains(bundleID) else {
            return
        }

        NSLog(
            "[MakLock] Protected app detected: %@ (%@)",
            protectedApp.name,
            bundleID
        )

        pendingLockBundleIDs.insert(bundleID)

        detectedApp = protectedApp
        onProtectedAppDetected?(protectedApp)
    }
}
