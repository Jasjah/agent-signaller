import AppKit
import SignalerCore

/// Shared state → color mapping used by every style (dots, miners, frame).
/// `active` is true for the states that should glow / pulse.
func agentColor(_ state: AgentState?) -> (color: NSColor, active: Bool) {
    switch state {
    case .working: return (.systemRed, true)
    case .waiting: return (.systemYellow, true)
    case .done:    return (.systemGreen, true)
    case nil:      return (NSColor.systemGreen.withAlphaComponent(0.25), false) // idle
    }
}

/// A click-through colored border around each screen — the Frame style. The
/// border shows the aggregate state and pulses while any session is working.
final class FrameOverlay {
    private var windows: [NSWindow] = []
    private var visible = false
    private var lastState: AgentState?

    static let inset: CGFloat = 5
    static let lineWidth: CGFloat = 4

    init() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    // MARK: - Lifecycle

    func show() {
        if windows.isEmpty { build() }
        visible = true
        windows.forEach { $0.orderFrontRegardless() }
        apply(lastState)
    }

    func hide() {
        visible = false
        windows.forEach { $0.orderOut(nil) }
    }

    func update(state: AgentState?) {
        lastState = state
        guard visible else { return }
        apply(state)
    }

    // MARK: - Internals

    @objc private func screensChanged() {
        let wasVisible = visible
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        if wasVisible { show() }
    }

    private func build() {
        for screen in NSScreen.screens {
            // Full display frame (not visibleFrame) so the border hugs the true
            // screen edges; at .statusBar level it draws above the Dock/menu bar.
            let f = screen.frame
            let w = NSWindow(contentRect: f, styleMask: .borderless, backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = true          // click-through
            w.level = .statusBar
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            let v = BorderView(frame: NSRect(origin: .zero, size: f.size))
            v.inset = FrameOverlay.inset
            v.stroke = FrameOverlay.lineWidth
            w.contentView = v
            windows.append(w)
        }
    }

    private func apply(_ state: AgentState?) {
        for w in windows {
            guard let v = w.contentView as? BorderView else { continue }
            if state == nil {
                v.setColor(nil)                              // idle → no border
            } else {
                let (c, _) = agentColor(state)
                v.setColor(c, pulse: state == .working)
            }
        }
    }
}

/// Draws a stroked rounded-rect border inset from the view edges.
private final class BorderView: NSView {
    var inset: CGFloat = 5
    var stroke: CGFloat = 8
    private let shape = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        shape.fillColor = nil
        layer?.addSublayer(shape)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        shape.frame = bounds
        shape.lineWidth = stroke
        let r = bounds.insetBy(dx: inset + stroke / 2, dy: inset + stroke / 2)
        shape.path = CGPath(roundedRect: r, cornerWidth: 16, cornerHeight: 16, transform: nil)
    }

    func setColor(_ color: NSColor?, pulse: Bool = false) {
        shape.removeAnimation(forKey: "pulse")
        guard let color = color else {
            shape.strokeColor = NSColor.clear.cgColor
            return
        }
        shape.strokeColor = color.cgColor
        let steady: Float = 0.75   // lighter than a solid border
        if pulse {
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = steady
            a.toValue = 0.25
            a.duration = 0.8
            a.autoreverses = true
            a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            shape.add(a, forKey: "pulse")
        } else {
            shape.opacity = steady
        }
    }
}
