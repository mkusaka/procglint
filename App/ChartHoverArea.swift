import AppKit
import SwiftUI

/// Hosted Charts do not consistently deliver SwiftUI hover events; keep native tracking, not native drawing.
struct ChartHoverArea: NSViewRepresentable {
    var changed: (CGPoint?) -> Void

    func makeNSView(context _: Context) -> ChartTrackingView {
        ChartTrackingView(changed: changed)
    }

    func updateNSView(_ view: ChartTrackingView, context _: Context) {
        view.changed = changed
    }
}

final class ChartTrackingView: NSView {
    var changed: (CGPoint?) -> Void
    private var tracking: NSTrackingArea?

    init(changed: @escaping (CGPoint?) -> Void) {
        self.changed = changed
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Programmatic UI only")
    }

    override var isFlipped: Bool {
        true
    }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        changed(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with _: NSEvent) {
        changed(nil)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            changed(nil)
        }
        super.viewWillMove(toWindow: newWindow)
    }
}
