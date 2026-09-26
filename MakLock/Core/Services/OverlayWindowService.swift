import AppKit
import ApplicationServices
import SwiftUI

/// Manages the small lock dialog lifecycle.
final class OverlayWindowService {
    static let shared = OverlayWindowService()

    private var overlayWindow: LockOverlayWindow?
    private var timeoutTimer: Timer?
    private var currentApp: ProtectedApp?

    /// Callback when the app is successfully unlocked.
    var onUnlocked: ((String) -> Void)?

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    /// Hide the protected app first, then display the small lock dialog.
    func show(for app: ProtectedApp) {
        guard overlayWindow == nil else {
            return
        }

        currentApp = app

        // Hide the protected application BEFORE showing MakLock.
        // This prevents its chat/content from being visible behind
        // the authentication popup.
        hideProtectedApp(
            bundleIdentifier: app.bundleIdentifier
        )

        createOverlayWindow(for: app)
        startTimeoutTimer()

        // Do NOT activate MakLock here.
        // The popup is a non-activating panel and can be brought
        // forward without generating another application-switch
        // event.
        overlayWindow?.orderFrontRegardless()
        overlayWindow?.makeKeyAndOrderFront(nil)

        NSLog(
            "[MakLock] Small lock dialog shown for: %@",
            app.name
        )
    }

    /// Successful authentication.
    func hide() {
        stopTimeoutTimer()
        AuthenticationService.shared.cancelAuthentication()

        let bundleID = currentApp?.bundleIdentifier
        let appName = currentApp?.name ?? "app"

        if let bundleID {
            AppMonitorService.shared.markAuthenticated(bundleID)
        }

        closeOverlayWindow()
        currentApp = nil

        if let bundleID {
            DispatchQueue.main.asyncAfter(
                deadline: .now() + 0.15
            ) { [weak self] in
                self?.activateProtectedApp(
                    bundleIdentifier: bundleID
                )
            }
        }

        NSLog(
            "[MakLock] Lock dismissed after authentication: %@",
            appName
        )
    }

    /// User cancelled the lock.
    /// The protected app remains hidden and unauthenticated.
    func cancel() {
        stopTimeoutTimer()
        AuthenticationService.shared.cancelAuthentication()

        let bundleID = currentApp?.bundleIdentifier

        if let bundleID {
            AppMonitorService.shared.cancelPendingLock(
                for: bundleID
            )
        }

        closeOverlayWindow()
        currentApp = nil

        if let bundleID {
            hideProtectedApp(bundleIdentifier: bundleID)
        }

        NSLog(
            "[MakLock] Lock cancelled; protected app remains locked"
        )
    }

    /// Panic key / emergency dismissal.
    /// Never marks the protected app authenticated.
    func dismissAll() {
        cancel()
    }

    var isShowing: Bool {
        overlayWindow != nil
    }

    var currentBundleIdentifier: String? {
        currentApp?.bundleIdentifier
    }

    var currentAppName: String? {
        currentApp?.name
    }

    /// Retained for compatibility with existing callers.
    func setTouchIDMode(_ active: Bool) {
        overlayWindow?.ignoresMouseEvents = active
    }

    /// Make the popup capable of receiving keyboard/password input.
    func enableKeyboardInput() {
        overlayWindow?.ignoresMouseEvents = false
        overlayWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Screen Management

    @objc private func screensDidChange(
        _ notification: Notification
    ) {
        guard let window = overlayWindow else {
            return
        }

        let screen = NSScreen.main ?? NSScreen.screens.first

        if let screen {
            window.reposition(to: screen)
            window.orderFrontRegardless()
        }
    }

    private func createOverlayWindow(for app: ProtectedApp) {
        guard let screen =
            NSScreen.main ?? NSScreen.screens.first else {
            return
        }

        let window = LockOverlayWindow(for: screen)

        let overlayView = LockOverlayView(
            appName: app.name,
            bundleIdentifier: app.bundleIdentifier,
            onDismiss: { [weak self] in
                let name = self?.currentApp?.name ?? "app"

                self?.hide()
                self?.onUnlocked?(name)
            },
            onCancel: { [weak self] in
                self?.cancel()
            }
        )

        window.contentView = NSHostingView(
            rootView: overlayView
        )

        overlayWindow = window

        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func closeOverlayWindow() {
        overlayWindow?.close()
        overlayWindow = nil
    }

    // MARK: - Protected App Management

    // MARK: - Protected App Management

    /// Hide a protected application.
    ///
    /// NSRunningApplication.hide() is attempted first.
    /// If it doesn't succeed and MakLock has Accessibility trust,
    /// use the application-level AX hidden attribute as a fallback.
    @discardableResult
    private func hideProtectedApp(
        bundleIdentifier: String
    ) -> Bool {
        guard let app =
            NSWorkspace.shared.runningApplications.first(
                where: {
                    $0.bundleIdentifier == bundleIdentifier
                }
            ) else {
            return false
        }

        var hidden = app.hide()

        if AXIsProcessTrusted() {
            let axApp = AXUIElementCreateApplication(
                app.processIdentifier
            )

            let result = AXUIElementSetAttributeValue(
                axApp,
                kAXHiddenAttribute as CFString,
                kCFBooleanTrue
            )

            if result == .success {
                hidden = true

                NSLog(
                    "[MakLock] AX hidden fallback succeeded: %@",
                    bundleIdentifier
                )
            }
        }

        // Retry once on the next main-run-loop turn.
        // NSRunningApplication properties can be asynchronous.
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 0.05
        ) { [weak self] in
            guard let self,
                  let runningApp =
                    NSWorkspace.shared.runningApplications.first(
                        where: {
                            $0.bundleIdentifier == bundleIdentifier
                        }
                    ) else {
                return
            }

            if !runningApp.isHidden {
                _ = runningApp.hide()

                if AXIsProcessTrusted() {
                    let axApp = AXUIElementCreateApplication(
                        runningApp.processIdentifier
                    )

                    _ = AXUIElementSetAttributeValue(
                        axApp,
                        kAXHiddenAttribute as CFString,
                        kCFBooleanTrue
                    )
                }

                NSLog(
                    "[MakLock] Retried hiding protected app: %@",
                    bundleIdentifier
                )
            }
        }

        NSLog(
            "[MakLock] Protected app hide requested: %@ (success=%@)",
            bundleIdentifier,
            hidden ? "YES" : "NO"
        )

        return hidden
    }

    /// Unhide and activate the protected application after successful auth.
    private func activateProtectedApp(
        bundleIdentifier: String
    ) {
        guard let app =
            NSWorkspace.shared.runningApplications.first(
                where: {
                    $0.bundleIdentifier == bundleIdentifier
                }
            ) else {
            NSLog(
                "[MakLock] App not running, skipping activation: %@",
                bundleIdentifier
            )
            return
        }

        _ = app.unhide()

        if AXIsProcessTrusted() {
            let axApp = AXUIElementCreateApplication(
                app.processIdentifier
            )

            _ = AXUIElementSetAttributeValue(
                axApp,
                kAXHiddenAttribute as CFString,
                kCFBooleanFalse
            )
        }

        app.activate()

        NSLog(
            "[MakLock] Activated app: %@",
            bundleIdentifier
        )
    }

    // MARK: - Timeout

    private func startTimeoutTimer() {
        let timeout = SafetyManager.isDevMode
            ? SafetyManager.devModeTimeout
            : SafetyManager.overlayTimeout

        timeoutTimer = Timer.scheduledTimer(
            withTimeInterval: timeout,
            repeats: false
        ) { [weak self] _ in
            NSLog(
                "[MakLock Safety] Lock dialog timeout reached (%.0fs) — cancelling",
                timeout
            )

            self?.cancel()
        }
    }

    private func stopTimeoutTimer() {
        timeoutTimer?.invalidate()
        timeoutTimer = nil
    }
}
