import AppKit
import Combine

/// Monitors protected applications and owns the lock/session state.
///
/// V5 deliberately does not create any overlay window. When a protected app
/// becomes active, the app itself is hidden first, then Apple's native
/// LocalAuthentication UI is presented. On success the app is unhidden and
/// activated. This avoids competing with macOS focus/window management.
final class AppMonitorService: ObservableObject {
    static let shared = AppMonitorService()

    @Published var detectedApp: ProtectedApp?
    var onProtectedAppDetected: ((ProtectedApp) -> Void)?

    private var cancellables = Set<AnyCancellable>()
    private var authenticatedApps: Set<String> = []
    private var pendingLockBundleIDs: Set<String> = []
    private var authenticatedPIDs: [String: pid_t] = [:]
    private var visibleWindowCounts: [String: Int] = [:]
    private var windowTimer: Timer?

    private init() {}

    func startMonitoring() {
        stopMonitoring()

        let center = NSWorkspace.shared.notificationCenter

        center.publisher(for: NSWorkspace.didLaunchApplicationNotification)
            .compactMap { $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
            .sink { [weak self] app in
                self?.handleLaunch(app)
            }
            .store(in: &cancellables)

        center.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .compactMap { $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
            .sink { [weak self] app in
                self?.handleActivation(app)
            }
            .store(in: &cancellables)

        center.publisher(for: NSWorkspace.didTerminateApplicationNotification)
            .compactMap { $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
            .sink { [weak self] app in
                guard let self, let id = app.bundleIdentifier else { return }
                self.clearAuthentication(for: id)
                self.pendingLockBundleIDs.remove(id)

                if OverlayWindowService.shared.currentBundleIdentifier == id {
                    OverlayWindowService.shared.handleProtectedAppTermination()
                }
            }
            .store(in: &cancellables)

        windowTimer = Timer.scheduledTimer(withTimeInterval: 0.30, repeats: true) {
            [weak self] _ in
            self?.pollWindows()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.checkRunningApps()
        }

        NSLog("[MakLock] V5 app monitor started")
    }

    func stopMonitoring() {
        cancellables.removeAll()
        windowTimer?.invalidate()
        windowTimer = nil
    }

    func markAuthenticated(_ bundleIdentifier: String) {
        guard let app = runningApplication(bundleIdentifier) else { return }

        authenticatedApps.insert(bundleIdentifier)
        authenticatedPIDs[bundleIdentifier] = app.processIdentifier
        visibleWindowCounts[bundleIdentifier] = visibleWindowCount(app)
        pendingLockBundleIDs.remove(bundleIdentifier)

        NSLog("[MakLock] Authenticated: %@ pid=%d",
              bundleIdentifier, app.processIdentifier)
    }

    func clearAuthentication(for bundleIdentifier: String) {
        authenticatedApps.remove(bundleIdentifier)
        authenticatedPIDs.removeValue(forKey: bundleIdentifier)
        visibleWindowCounts.removeValue(forKey: bundleIdentifier)
        pendingLockBundleIDs.remove(bundleIdentifier)
    }

    func clearAllAuthentications() {
        authenticatedApps.removeAll()
        authenticatedPIDs.removeAll()
        visibleWindowCounts.removeAll()
        pendingLockBundleIDs.removeAll()
    }

    func cancelPendingLock(for bundleIdentifier: String) {
        pendingLockBundleIDs.remove(bundleIdentifier)
    }

    func isAuthenticated(_ bundleIdentifier: String) -> Bool {
        authenticatedApps.contains(bundleIdentifier)
    }

    private func handleLaunch(_ app: NSRunningApplication) {
        guard let id = app.bundleIdentifier else { return }
        clearAuthentication(for: id)
        handleProtectedEvent(app)
    }

    private func handleActivation(_ app: NSRunningApplication) {
        guard let activeID = app.bundleIdentifier else { return }

        // MakLock itself and Apple's authentication agent are not protected-app
        // switches. In particular, never cancel a native auth session merely
        // because SecurityAgent becomes visible.
        if activeID == Bundle.main.bundleIdentifier ||
            activeID == "com.apple.SecurityAgent" ||
            activeID == "com.apple.loginwindow" {
            return
        }

        if isProtected(activeID) {
            if let authenticatedPID = authenticatedPIDs[activeID],
               authenticatedPID != app.processIdentifier {
                clearAuthentication(for: activeID)
            }

            handleProtectedEvent(app)
            return
        }

        // A real switch to another normal application ends protected sessions.
        // The currently locked app remains hidden and unauthenticated.
        let authenticated = Array(authenticatedApps)
        for id in authenticated {
            clearAuthentication(for: id)
            NSLog("[MakLock] App switch; auth cleared: %@", id)
        }

        if OverlayWindowService.shared.isShowing {
            OverlayWindowService.shared.cancelForExternalSwitch()
        }
    }

    private func handleProtectedEvent(_ app: NSRunningApplication) {
        guard let id = app.bundleIdentifier,
              isProtected(id),
              Defaults.shared.appSettings.isProtectionEnabled,
              !SafetyManager.isBlacklisted(id) else {
            return
        }

        if let authenticatedPID = authenticatedPIDs[id],
           authenticatedPID != app.processIdentifier {
            clearAuthentication(for: id)
        }

        guard !authenticatedApps.contains(id),
              !pendingLockBundleIDs.contains(id),
              !OverlayWindowService.shared.isShowing,
              let protectedApp = Defaults.shared.protectedApps.first(where: {
                  $0.bundleIdentifier == id && $0.isEnabled
              }) else {
            return
        }

        pendingLockBundleIDs.insert(id)
        detectedApp = protectedApp
        onProtectedAppDetected?(protectedApp)
        NSLog("[MakLock] V5 lock requested: %@", id)
    }

    private func checkRunningApps() {
        guard Defaults.shared.appSettings.isProtectionEnabled else { return }

        for app in NSWorkspace.shared.runningApplications {
            guard let id = app.bundleIdentifier,
                  isProtected(id),
                  !authenticatedApps.contains(id),
                  !pendingLockBundleIDs.contains(id),
                  !OverlayWindowService.shared.isShowing,
                  let protectedApp = Defaults.shared.protectedApps.first(where: {
                      $0.bundleIdentifier == id && $0.isEnabled
                  }) else {
                continue
            }

            pendingLockBundleIDs.insert(id)
            detectedApp = protectedApp
            onProtectedAppDetected?(protectedApp)
            return
        }
    }

    private func pollWindows() {
        guard Defaults.shared.appSettings.isProtectionEnabled else { return }

        for id in Array(authenticatedApps) {
            guard let app = runningApplication(id) else {
                clearAuthentication(for: id)
                continue
            }

            guard authenticatedPIDs[id] == app.processIdentifier else {
                clearAuthentication(for: id)
                continue
            }

            let count = visibleWindowCount(app)
            let previous = visibleWindowCounts[id] ?? count
            visibleWindowCounts[id] = count

            // Closing/minimizing the last window ends this authentication session.
            if previous > 0 && count == 0 {
                clearAuthentication(for: id)
                NSLog("[MakLock] Last protected window closed/minimized: %@", id)
            }
        }
    }

    private func isProtected(_ bundleID: String) -> Bool {
        Defaults.shared.protectedApps.contains {
            $0.bundleIdentifier == bundleID && $0.isEnabled
        }
    }

    private func runningApplication(_ bundleID: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == bundleID
        }
    }

    private func visibleWindowCount(_ app: NSRunningApplication) -> Int {
        if AXIsProcessTrusted() {
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            var value: CFTypeRef?

            if AXUIElementCopyAttributeValue(
                axApp, kAXWindowsAttribute as CFString, &value
            ) == .success,
               let windows = value as? [AXUIElement] {

                return windows.reduce(into: 0) { count, window in
                    var minimized: CFTypeRef?
                    let result = AXUIElementCopyAttributeValue(
                        window,
                        kAXMinimizedAttribute as CFString,
                        &minimized
                    )
                    let isMinimized =
                        result == .success &&
                        (minimized as? NSNumber)?.boolValue == true
                    if !isMinimized { count += 1 }
                }
            }
        }

        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return 1
        }

        return windows.reduce(into: 0) { count, info in
            guard let pid = info[kCGWindowOwnerPID as String] as? Int32,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  pid == app.processIdentifier,
                  layer == 0 else {
                return
            }
            count += 1
        }
    }
}
