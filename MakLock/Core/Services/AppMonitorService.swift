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
        let settings = Defaults.shared.appSettings

        guard settings.isProtectionEnabled else {
            return
        }

        let protectedApps = Defaults.shared.protectedApps.filter {
            $0.isEnabled
        }

        let workspace = NSWorkspace.shared

        let runningApps = workspace.runningApplications

        let protectedIDs = Set(
            protectedApps.map { $0.bundleIdentifier }
        )

        // Remove state for apps that are no longer protected.
        for bundleID in protectedWindowState.keys
        where !protectedIDs.contains(bundleID) {
            protectedWindowState.removeValue(forKey: bundleID)
        }

        // IMPORTANT:
        // Track ALL protected apps, not only authenticated apps.
        //
        // This allows:
        //     window exists -> no window -> window exists
        //
        // to work even after authentication is cleared.
        for protectedApp in protectedApps {
            let bundleID = protectedApp.bundleIdentifier

            guard let app = runningApps.first(
                where: {
                    $0.bundleIdentifier == bundleID
                }
            ) else {
                // Process isn't running.
                protectedWindowState[bundleID] = false
                continue
            }

            let hasWindows = appHasWindows(app)
            let previousState = protectedWindowState[bundleID]

            protectedWindowState[bundleID] = hasWindows

            // ------------------------------------------------
            // Last normal window closed.
            // ------------------------------------------------
            if previousState == true && !hasWindows {
                if authenticatedApps.contains(bundleID) {
                    authenticatedApps.remove(bundleID)
                    pendingLockBundleIDs.remove(bundleID)

                    NSLog(
                        "[MakLock] Last normal window closed, auth cleared: %@",
                        bundleID
                    )
                }

                continue
            }

            // ------------------------------------------------
            // Window reappeared after previously having none.
            // If the app is frontmost and isn't authenticated,
            // require the lock again.
            // ------------------------------------------------
            if previousState == false,
               hasWindows,
               workspace.frontmostApplication?.bundleIdentifier == bundleID,
               !authenticatedApps.contains(bundleID),
               !pendingLockBundleIDs.contains(bundleID),
               !OverlayWindowService.shared.isShowing {

                NSLog(
                    "[MakLock] Protected app window reopened: %@",
                    bundleID
                )

                handleAppEvent(app)
            }
        }
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
