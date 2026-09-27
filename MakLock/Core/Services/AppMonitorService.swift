import AppKit
import Combine

/// Owns the protected-app authentication state.
///
/// Rules:
/// - A protected app is locked by default.
/// - A successful native LocalAuthentication evaluation creates a session.
/// - Any real app switch away invalidates that session.
/// - A newly launched process always starts a new session.
/// - Closing/minimizing the last protected window invalidates the session.
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
                guard let self else { return }
                if let id = app.bundleIdentifier {
                    self.clearAuthentication(for: id)
                    self.pendingLockBundleIDs.remove(id)
                }
                self.handleAppEvent(app)
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

        windowTimer = Timer.scheduledTimer(withTimeInterval: 0.20, repeats: true) {
            [weak self] _ in
            self?.pollWindows()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.checkRunningApps()
        }

        NSLog("[MakLock] App monitor started")
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

    private func handleActivation(_ app: NSRunningApplication) {
        guard let activeID = app.bundleIdentifier else { return }

        // If a protected app becomes frontmost, it must either already have a
        // valid session or immediately enter a new lock session.
        if isProtected(activeID) {
            if let authenticatedPID = authenticatedPIDs[activeID],
               authenticatedPID != app.processIdentifier {
                clearAuthentication(for: activeID)
            }

            handleAppEvent(app)
            return
        }

        // A real switch to any other application invalidates every protected
        // app session. This is deliberately independent of deactivation timing.
        let protectedIDs = Defaults.shared.protectedApps
            .filter { $0.isEnabled }
            .map { $0.bundleIdentifier }

        for id in authenticatedApps where protectedIDs.contains(id) {
            clearAuthentication(for: id)
            NSLog("[MakLock] App switch; auth cleared: %@", id)
        }

        // If a lock prompt is currently displayed and the user activates a
        // different normal app, dismiss only the prompt. The protected app
        // remains unauthenticated and will prompt again when returned to.
        if OverlayWindowService.shared.isShowing,
           let lockedID = OverlayWindowService.shared.currentBundleIdentifier,
           activeID != lockedID,
           activeID != Bundle.main.bundleIdentifier,
           activeID != "com.apple.SecurityAgent",
           activeID != "com.apple.loginwindow" {
            OverlayWindowService.shared.cancelForExternalSwitch()
        }
    }

    private func handleAppEvent(_ app: NSRunningApplication) {
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
        NSLog("[MakLock] Lock requested: %@", id)
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

            if let pid = authenticatedPIDs[id],
               pid != app.processIdentifier {
                clearAuthentication(for: id)
                continue
            }

            let count = visibleWindowCount(app)
            let previous = visibleWindowCounts[id] ?? count
            visibleWindowCounts[id] = count

            // Red X or minimize of the last window ends the session.
            if previous > 0 && count == 0 {
                clearAuthentication(for: id)
                NSLog("[MakLock] Last window closed/minimized: %@", id)
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
