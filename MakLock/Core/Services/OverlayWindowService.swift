import AppKit
import SwiftUI
import CoreGraphics
import ApplicationServices

/// Manages the small lock card and the window-sized blocker.
final class OverlayWindowService {

    static let shared = OverlayWindowService()

    private var overlayWindow: LockOverlayWindow?
    private var timeoutTimer: Timer?
    private var currentApp: ProtectedApp?

    /// Called after successful authentication.
    var onUnlocked: ((String) -> Void)?

    private init() {}

    // MARK: - Show / Hide

    func show(for app: ProtectedApp) {
        // One authentication session at a time.
        guard currentApp == nil else {
            return
        }

        currentApp = app

        let bundleID = app.bundleIdentifier
        let appName = app.name

        // Hide the protected app BEFORE invoking the native
        // macOS authentication UI.
        _ = hideProtectedApp(
            bundleIdentifier: bundleID
        )

        // Give macOS a moment to finish hiding the app before
        // LAContext presents its native authentication dialog.
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 0.15
        ) { [weak self] in

            guard let self,
                  self.currentApp?.bundleIdentifier == bundleID
            else {
                return
            }

            // Retry the hide immediately before authentication.
            _ = self.hideProtectedApp(
                bundleIdentifier: bundleID
            )

            NSLog(
                "[MakLock] Starting native macOS authentication for %@",
                appName
            )

            AuthenticationService.shared
                .authenticateWithSystemFallback(
                    reason: "Unlock \(appName)"
                ) { [weak self] result in

                    DispatchQueue.main.async {
                        guard let self,
                              self.currentApp?.bundleIdentifier == bundleID
                        else {
                            return
                        }

                        switch result {

                        case .success:
                            // Native authentication succeeded.
                            // hide() will mark the session authenticated
                            // and restore the protected application.
                            self.hide()

                        case .cancelled:
                            // User cancelled native authentication.
                            // Keep the protected app hidden and locked.
                            self.cancel()

                        case .failure:
                            // Authentication failed.
                            // Do not unlock the protected app.
                            self.cancel()
                        }
                    }
                }
        }

        NSLog(
            "[MakLock] Native authentication requested for %@",
            appName
        )
    }

    /// Successful authentication.
    func hide() {

        stopTimeoutTimer()
        AuthenticationService.shared.cancelAuthentication()

        guard let app = currentApp else {
            closeOverlayWindow()
            return
        }

        let bundleID = app.bundleIdentifier
        let name = app.name

        AppMonitorService.shared.markAuthenticated(bundleID)

        closeOverlayWindow()
        currentApp = nil

        // Bring the protected application back after the lock card
        // has completely disappeared.
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 0.12
        ) { [weak self] in

            self?.activateProtectedApp(
                bundleIdentifier: bundleID
            )
        }

        NSLog(
            "[MakLock] Protected app unlocked: %@",
            name
        )
    }

    /// User cancelled without authenticating.
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

            hideProtectedApp(
                bundleIdentifier: bundleID
            )
        }

        NSLog(
            "[MakLock] Lock cancelled; protected app remains locked"
        )
    }

    /// Panic / emergency dismissal.
    /// Does NOT authenticate the protected app.
    func dismissAll() {
        cancel()
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

    // MARK: - Input

    func setTouchIDMode(_ active: Bool) {
        overlayWindow?.ignoresMouseEvents = active
    }

    func enableKeyboardInput() {

        overlayWindow?.ignoresMouseEvents = false
        overlayWindow?.makeKeyAndOrderFront(nil)

        NSApp.activate(
            ignoringOtherApps: true
        )
    }

    // MARK: - Window Creation

    private func createOverlayWindow(
        for app: ProtectedApp,
        frame: NSRect
    ) {

        let window = LockOverlayWindow(
            frame: frame
        )

        let view = LockOverlayView(
            appName: app.name,
            bundleIdentifier: app.bundleIdentifier,

            onDismiss: { [weak self] in

                let name =
                    self?.currentApp?.name ?? "app"

                self?.hide()
                self?.onUnlocked?(name)
            },

            onCancel: { [weak self] in
                self?.cancel()
            }
        )

        window.contentView = NSHostingView(
            rootView: view
        )

        overlayWindow = window

        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func closeOverlayWindow() {

        overlayWindow?.close()
        overlayWindow = nil
    }

    // MARK: - Protected Window Geometry

    /// Finds the largest normal-level onscreen window owned by
    /// the protected application.
    ///
    /// Quartz Window Services provides the window bounds and owner PID.
    /// The result is converted from Quartz coordinates to AppKit
    /// coordinates for the overlay panel.
    private func protectedWindowFrame(
        for protectedApp: ProtectedApp
    ) -> NSRect? {

        guard let runningApp =
            NSWorkspace.shared.runningApplications.first(
                where: {
                    $0.bundleIdentifier ==
                    protectedApp.bundleIdentifier
                }
            ) else {
            return nil
        }

        guard let windowList =
            CGWindowListCopyWindowInfo(
                [
                    .optionOnScreenOnly,
                    .excludeDesktopElements
                ],
                kCGNullWindowID
            ) as? [[String: Any]] else {
            return nil
        }

        var bestRect: CGRect?
        var bestArea: CGFloat = 0

        for info in windowList {

            guard
                let ownerPID =
                    info[kCGWindowOwnerPID as String] as? Int32,
                ownerPID == runningApp.processIdentifier,

                let layer =
                    info[kCGWindowLayer as String] as? Int,
                layer == 0,

                let bounds =
                    info[kCGWindowBounds as String]
                    as? [String: Any]
            else {
                continue
            }

            let x =
                (bounds["X"] as? NSNumber)?
                    .doubleValue ?? 0

            let y =
                (bounds["Y"] as? NSNumber)?
                    .doubleValue ?? 0

            let width =
                (bounds["Width"] as? NSNumber)?
                    .doubleValue ?? 0

            let height =
                (bounds["Height"] as? NSNumber)?
                    .doubleValue ?? 0

            guard width > 200,
                  height > 150 else {
                continue
            }

            let rect = CGRect(
                x: x,
                y: y,
                width: width,
                height: height
            )

            let area =
                rect.width * rect.height

            if area > bestArea {

                bestArea = area
                bestRect = rect
            }
        }

        guard let quartzRect = bestRect else {
            return nil
        }

        let screen =
            NSScreen.main ??
            NSScreen.screens.first

        guard let screen else {
            return nil
        }

        // Quartz uses a top-left origin for window coordinates;
        // AppKit uses a bottom-left origin.
        let appKitY =
            screen.frame.maxY -
            quartzRect.maxY

        return NSRect(
            x: quartzRect.origin.x,
            y: appKitY,
            width: quartzRect.width,
            height: quartzRect.height
        )
    }

    // MARK: - Screen Changes

    @objc private func screensDidChange(
        _ notification: Notification
    ) {

        guard let window = overlayWindow,
              let app = currentApp else {
            return
        }

        if let frame = protectedWindowFrame(
            for: app
        ) {
            window.reposition(
                to: frame
            )
            window.orderFrontRegardless()
        }
    }

    // MARK: - Protected App Management

    @discardableResult
    private func hideProtectedApp(
        bundleIdentifier: String
    ) -> Bool {

        guard let app =
            NSWorkspace.shared.runningApplications.first(
                where: {
                    $0.bundleIdentifier ==
                    bundleIdentifier
                }
            ) else {
            return false
        }

        var hidden = app.hide()

        // Accessibility fallback is only needed for Cancel.
        if !hidden && AXIsProcessTrusted() {

            let axApp =
                AXUIElementCreateApplication(
                    app.processIdentifier
                )

            let result =
                AXUIElementSetAttributeValue(
                    axApp,
                    kAXHiddenAttribute as CFString,
                    kCFBooleanTrue
                )

            hidden = result == .success
        }

        NSLog(
            "[MakLock] Protected app hide requested: %@ success=%@",
            bundleIdentifier,
            hidden ? "YES" : "NO"
        )

        return hidden
    }

    private func activateProtectedApp(
        bundleIdentifier: String
    ) {

        guard let app =
            NSWorkspace.shared.runningApplications.first(
                where: {
                    $0.bundleIdentifier ==
                    bundleIdentifier
                }
            ) else {

            NSLog(
                "[MakLock] App not running: %@",
                bundleIdentifier
            )

            return
        }

        _ = app.unhide()

        app.activate(
            options: [
                .activateIgnoringOtherApps
            ]
        )

        NSLog(
            "[MakLock] Activated protected app: %@",
            bundleIdentifier
        )
    }

    // MARK: - Timeout

    private func startTimeoutTimer() {

        let timeout =
            SafetyManager.isDevMode
            ? SafetyManager.devModeTimeout
            : SafetyManager.overlayTimeout

        timeoutTimer =
            Timer.scheduledTimer(
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
