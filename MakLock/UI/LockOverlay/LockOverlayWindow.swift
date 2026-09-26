import AppKit

/// Small centered lock panel.
/// The protected application is hidden while this panel is shown,
/// so protected content cannot remain visible behind it.
final class LockOverlayWindow: NSPanel {
    private let panelSize = NSSize(width: 420, height: 360)

    init(for screen: NSScreen) {
        let visibleFrame = screen.visibleFrame

        let origin = NSPoint(
            x: visibleFrame.midX - panelSize.width / 2,
            y: visibleFrame.midY - panelSize.height / 2
        )

        let frame = NSRect(
            origin: origin,
            size: panelSize
        )

        super.init(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        level = .floating

        collectionBehavior = [
            .moveToActiveSpace,
            .fullScreenAuxiliary,
            .stationary
        ]

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        ignoresMouseEvents = false
    }

    func reposition(to screen: NSScreen) {
        let visibleFrame = screen.visibleFrame

        let origin = NSPoint(
            x: visibleFrame.midX - frame.width / 2,
            y: visibleFrame.midY - frame.height / 2
        )

        setFrameOrigin(origin)
    }

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }
}
