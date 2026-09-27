import AppKit

/// Owns the single lock session and the privacy shield.
///
/// The shield is a window-sized, non-activating black panel placed directly
/// over the protected application's window. It blocks mouse/keyboard access to
/// the app without presenting any custom authentication UI. LocalAuthentication
/// owns the actual Touch ID/password dialog.
final class OverlayWindowService {
    static let shared = OverlayWindowService()

    private var privacyWindow: LockOverlayWindow?
    private var frameTimer: Timer?
    private var retryTimer: Timer?
    private var currentApp: ProtectedApp?
    private var sessionID = UUID()

    var onUnlocked: ((String) -> Void)?

    private init() {}

    func show(for app: ProtectedApp) {
        guard currentApp == nil else { return }

        currentApp = app
        sessionID = UUID()

        let id = sessionID
        let bundleID = app.bundleIdentifier
        let name = app.name

        // The shield is created BEFORE authentication starts.
        waitForWindow(bundleID: bundleID, attempt: 0, session: id) {
            [weak self] in
            guard let self,
                  self.sessionID == id,
                  self.currentApp?.bundleIdentifier == bundleID else {
                return
            }

            self.installShield(bundleID: bundleID)
            self.startFrameTracking(bundleID: bundleID)
            self.authenticate(bundleID: bundleID, name: name, session: id)
        }
    }

    private func authenticate(
        bundleID: String,
        name: String,
        session: UUID
    ) {
        guard sessionID == session,
              currentApp?.bundleIdentifier == bundleID else { return }

        guard !AuthenticationService.shared.isAuthenticating else { return }

        AuthenticationService.shared.authenticateWithSystemFallback(
            reason: "Unlock (name)"
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self,
                      self.sessionID == session,
                      self.currentApp?.bundleIdentifier == bundleID else {
                    return
                }

                switch result {
                case .success:
                    self.finishUnlock(bundleID: bundleID, name: name)

                case .cancelled, .failure:
                    // The lock remains active. Re-open the native macOS
                    // authentication dialog instead of exposing the app.
                    self.retryTimer?.invalidate()
                    self.retryTimer = Timer.scheduledTimer(
                        withTimeInterval: 0.25,
                        repeats: false
                    ) { [weak self] _ in
                        self?.authenticate(
                            bundleID: bundleID,
                            name: name,
                            session: session
                        )
                    }
                }
            }
        }
    }

    private func finishUnlock(bundleID: String, name: String) {
        retryTimer?.invalidate()
        retryTimer = nil
        stopFrameTracking()

        AppMonitorService.shared.markAuthenticated(bundleID)

        // Remove only the privacy shield. We never activate or hide the target.
        closeShield()
        currentApp = nil

        onUnlocked?(name)
        NSLog("[MakLock] Unlock successful: %@", bundleID)
    }

    /// Compatibility path for Watch auto-unlock.
    func hide() {
        guard let app = currentApp else { return }
        finishUnlock(bundleID: app.bundleIdentifier, name: app.name)
    }

    /// Called when the user intentionally switches away while the lock dialog
    /// is active. No authentication is granted.
    func cancelForExternalSwitch() {
        guard currentApp != nil else { return }

        sessionID = UUID()
        retryTimer?.invalidate()
        retryTimer = nil
        AuthenticationService.shared.cancelAuthentication()
        stopFrameTracking()
        closeShield()

        if let id = currentApp?.bundleIdentifier {
            AppMonitorService.shared.cancelPendingLock(for: id)
        }

        currentApp = nil
    }

    func handleProtectedAppTermination() {
        sessionID = UUID()
        retryTimer?.invalidate()
        retryTimer = nil
        AuthenticationService.shared.cancelAuthentication()
        stopFrameTracking()
        closeShield()
        currentApp = nil
    }

    func dismissAll() {
        cancelForExternalSwitch()
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

    // Compatibility hooks retained for the legacy SwiftUI lock view that
    // remains in the target. V4 does not use that view for authentication.
    func setTouchIDMode(_ active: Bool) {
        privacyWindow?.ignoresMouseEvents = !active
    }

    func enableKeyboardInput() {
        // Native LocalAuthentication owns keyboard focus in V4.
    }

    // MARK: Privacy shield

    private func installShield(bundleID: String) {
        closeShield()

        let frame = protectedWindowFrame(bundleID: bundleID)
            ?? NSScreen.main?.frame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)

        let window = LockOverlayWindow(frame: frame)

        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        window.contentView = view

        // Screen-saver level ensures the shield is above WhatsApp even while
        // the native SecurityAgent dialog is presented. The panel is
        // non-activating, so it does not steal the authentication focus.
        window.level = .screenSaver
        window.orderFrontRegardless()

        privacyWindow = window
    }

    private func startFrameTracking(bundleID: String) {
        stopFrameTracking()

        frameTimer = Timer.scheduledTimer(
            withTimeInterval: 0.20,
            repeats: true
        ) { [weak self] _ in
            guard let self,
                  self.currentApp?.bundleIdentifier == bundleID,
                  let frame = self.protectedWindowFrame(bundleID: bundleID) else {
                return
            }

            self.privacyWindow?.setFrame(frame, display: true)
            self.privacyWindow?.orderFrontRegardless()
        }
    }

    private func stopFrameTracking() {
        frameTimer?.invalidate()
        frameTimer = nil
    }

    private func closeShield() {
        privacyWindow?.orderOut(nil)
        privacyWindow?.close()
        privacyWindow = nil
    }

    // MARK: Window geometry

    private func waitForWindow(
        bundleID: String,
        attempt: Int,
        session: UUID,
        completion: @escaping () -> Void
    ) {
        guard sessionID == session else { return }

        if protectedWindowFrame(bundleID: bundleID) != nil || attempt >= 20 {
            completion()
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            [weak self] in
            self?.waitForWindow(
                bundleID: bundleID,
                attempt: attempt + 1,
                session: session,
                completion: completion
            )
        }
    }

    private func protectedWindowFrame(bundleID: String) -> NSRect? {
        guard let app = runningApplication(bundleID) else { return nil }

        // Accessibility gives reliable global window geometry when permission
        // is available.
        if AXIsProcessTrusted() {
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            var focused: CFTypeRef?

            if AXUIElementCopyAttributeValue(
                axApp,
                kAXFocusedWindowAttribute as CFString,
                &focused
            ) == .success,
               let focused = focused as? AXUIElement,
               let frame = axWindowFrame(focused) {
                return frame
            }

            var windows: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                axApp,
                kAXWindowsAttribute as CFString,
                &windows
            ) == .success,
               let windows = windows as? [AXUIElement] {

                for window in windows {
                    var minimized: CFTypeRef?
                    let result = AXUIElementCopyAttributeValue(
                        window,
                        kAXMinimizedAttribute as CFString,
                        &minimized
                    )

                    let isMinimized =
                        result == .success &&
                        (minimized as? NSNumber)?.boolValue == true

                    if !isMinimized, let frame = axWindowFrame(window) {
                        return frame
                    }
                }
            }
        }

        return cgWindowFrame(bundleID: bundleID)
    }

    private func axWindowFrame(_ window: AXUIElement) -> NSRect? {
        var position: CFTypeRef?
        var size: CFTypeRef?

        guard AXUIElementCopyAttributeValue(
            window, kAXPositionAttribute as CFString, &position
        ) == .success,
        AXUIElementCopyAttributeValue(
            window, kAXSizeAttribute as CFString, &size
        ) == .success else {
            return nil
        }

        let positionAX = position as! AXValue
        let sizeAX = size as! AXValue

        var point = CGPoint.zero
        var dimensions = CGSize.zero

        guard AXValueGetValue(positionAX, .cgPoint, &point),
              AXValueGetValue(sizeAX, .cgSize, &dimensions),
              dimensions.width > 0,
              dimensions.height > 0 else {
            return nil
        }

        guard let main = NSScreen.main else { return nil }

        return NSRect(
            x: point.x,
            y: main.frame.maxY - point.y - dimensions.height,
            width: dimensions.width,
            height: dimensions.height
        )
    }

    private func cgWindowFrame(bundleID: String) -> NSRect? {
        guard let app = runningApplication(bundleID),
              let windows = CGWindowListCopyWindowInfo(
                  [.optionOnScreenOnly, .excludeDesktopElements],
                  kCGNullWindowID
              ) as? [[String: Any]] else {
            return nil
        }

        var best: CGRect?
        var area: CGFloat = 0

        for info in windows {
            guard let pid = info[kCGWindowOwnerPID as String] as? Int32,
                  pid == app.processIdentifier,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary else {
                continue
            }

            var rect = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(bounds, &rect) else {
                continue
            }

            let a = rect.width * rect.height
            if a > area {
                area = a
                best = rect
            }
        }

        guard let rect = best, let screen = NSScreen.main else { return nil }

        return NSRect(
            x: rect.minX,
            y: screen.frame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    private func runningApplication(_ bundleID: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == bundleID
        }
    }
}
