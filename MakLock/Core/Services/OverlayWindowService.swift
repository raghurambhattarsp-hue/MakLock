import AppKit

/// V5 lock controller.
///
/// There is intentionally no overlay window. The protected application is
/// hidden before Apple's native LocalAuthentication dialog is requested.
/// This keeps the protected app's content off-screen while authentication is
/// in progress without creating a competing top-level window.
final class OverlayWindowService {
    static let shared = OverlayWindowService()

    private var currentApp: ProtectedApp?
    private var sessionID = UUID()

    var onUnlocked: ((String) -> Void)?

    private init() {}

    func show(for app: ProtectedApp) {
        guard currentApp == nil else { return }
        guard let running = runningApplication(app.bundleIdentifier) else {
            AppMonitorService.shared.cancelPendingLock(for: app.bundleIdentifier)
            return
        }

        currentApp = app
        sessionID = UUID()
        let session = sessionID

        // Hide first. The user never sees the protected application's content
        // while LocalAuthentication is active.
        _ = running.hide()

        DispatchQueue.main.async { [weak self] in
            self?.beginAuthentication(app: app, session: session)
        }

        NSLog("[MakLock] V5 protected app hidden: %@", app.name)
    }

    private func beginAuthentication(app: ProtectedApp, session: UUID) {
        guard sessionID == session,
              currentApp?.bundleIdentifier == app.bundleIdentifier else {
            return
        }

        guard !AuthenticationService.shared.isAuthenticating else { return }

        AuthenticationService.shared.authenticateWithSystemFallback(
            reason: "Unlock (app.name)"
        ) { [weak self] result in
            guard let self,
                  self.sessionID == session,
                  self.currentApp?.bundleIdentifier == app.bundleIdentifier else {
                return
            }

            switch result {
            case .success:
                self.finishUnlock(app)

            case .cancelled, .failure:
                // Do not loop the system dialog. The protected app remains
                // hidden. The next deliberate activation of the app starts a
                // fresh native authentication session.
                self.finishFailedAuthentication(app)
            }
        }
    }

    private func finishUnlock(_ app: ProtectedApp) {
        AuthenticationService.shared.cancelAuthentication()
        AppMonitorService.shared.markAuthenticated(app.bundleIdentifier)

        currentApp = nil
        sessionID = UUID()

        guard let running = runningApplication(app.bundleIdentifier) else {
            onUnlocked?(app.name)
            return
        }

        running.unhide()

        DispatchQueue.main.async {
            running.activate()
        }

        onUnlocked?(app.name)
        NSLog("[MakLock] V5 unlock successful: %@", app.bundleIdentifier)
    }

    private func finishFailedAuthentication(_ app: ProtectedApp) {
        AuthenticationService.shared.cancelAuthentication()
        AppMonitorService.shared.cancelPendingLock(for: app.bundleIdentifier)
        currentApp = nil
        sessionID = UUID()

        // Keep the target hidden. No overlay, no forced activation, and no
        // repeated authentication loop.
        NSLog("[MakLock] V5 authentication did not succeed; app remains hidden: %@",
              app.bundleIdentifier)
    }

    /// Compatibility path used by Apple Watch auto-unlock.
    /// If a native lock is active, reveal the protected app without another
    /// authentication prompt because Watch has already been validated.
    func hide() {
        guard let app = currentApp else { return }
        finishUnlock(app)
    }

    /// External app switch cancels only the pending lock session. It never
    /// authenticates the protected app.
    func cancelForExternalSwitch() {
        guard let app = currentApp else { return }

        AuthenticationService.shared.cancelAuthentication()
        AppMonitorService.shared.cancelPendingLock(for: app.bundleIdentifier)
        currentApp = nil
        sessionID = UUID()

        NSLog("[MakLock] V5 lock cancelled by external app switch: %@",
              app.bundleIdentifier)
    }

    func handleProtectedAppTermination() {
        AuthenticationService.shared.cancelAuthentication()
        currentApp = nil
        sessionID = UUID()
    }

    func dismissAll() {
        // Panic/safety dismissal intentionally does not grant authentication.
        // If a target is currently hidden, reveal it so the user is never left
        // wondering where the application went.
        guard let app = currentApp else { return }

        AuthenticationService.shared.cancelAuthentication()
        AppMonitorService.shared.cancelPendingLock(for: app.bundleIdentifier)

        if let running = runningApplication(app.bundleIdentifier) {
            running.unhide()
        }

        currentApp = nil
        sessionID = UUID()
    }

    var isShowing: Bool {
        currentApp != nil
    }

    var currentBundleIdentifier: String? {
        currentApp?.bundleIdentifier
    }

    var currentAppName: String? {
        currentApp?.name
    }

    // Legacy hooks kept so the existing SwiftUI lock view still compiles.
    func setTouchIDMode(_ active: Bool) {}
    func enableKeyboardInput() {}

    private func runningApplication(_ bundleIdentifier: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == bundleIdentifier
        }
    }
}
