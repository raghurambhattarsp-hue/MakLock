import AppKit

/// Window-sized privacy shield. It never becomes key/main and therefore does
/// not steal focus from Apple's native LocalAuthentication UI.
final class LockOverlayWindow: NSPanel {
    /// New V4 initializer.
    init(frame: NSRect) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .screenSaver
        collectionBehavior = [
            .moveToActiveSpace,
            .fullScreenAuxiliary,
            .stationary
        ]
        isOpaque = true
        backgroundColor = .black
        ignoresMouseEvents = false
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
    }

    /// Legacy initializer retained because the unused SwiftUI lock-overlay
    /// source remains in the Xcode target.
    convenience init(for screen: NSScreen) {
        self.init(frame: screen.frame)
    }

    func reposition(to screen: NSScreen) {
        setFrame(screen.frame, display: true)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
