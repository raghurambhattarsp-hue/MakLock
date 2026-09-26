import AppKit

/// Window-sized lock blocker.
///
/// The window covers only the protected application's normal window.
/// The actual lock card inside it remains small.
final class LockOverlayWindow: NSPanel {

    init(frame: NSRect) {
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
        hasShadow = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        ignoresMouseEvents = false
    }

    func reposition(to frame: NSRect) {
        setFrame(frame, display: true)
    }

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }
}
