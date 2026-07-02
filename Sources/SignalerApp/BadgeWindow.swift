import AppKit
import SignalerCore
import ServiceManagement

/// Screen corner the badge can snap to.
enum Corner: String, CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight

    var title: String {
        switch self {
        case .topLeft: return "Top Left"
        case .topRight: return "Top Right"
        case .bottomLeft: return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        }
    }
}

private enum Defaults {
    static let corner = "corner"
    static let customOriginX = "customOriginX"
    static let customOriginY = "customOriginY"
    static let useCustomOrigin = "useCustomOrigin"
    static let soundEnabled = "soundEnabled"
    static let dotSize = "dotSize"
}

private enum Layout {
    static let gap: CGFloat = 8
    static let padH: CGFloat = 10
    static let padV: CGFloat = 10

    static let minDot: CGFloat = 12
    static let maxDot: CGFloat = 40       // a decent upper bound
    static let defaultDot: CGFloat = 19.2
    static let resizeGrip: CGFloat = 12   // trailing-edge zone that resizes

    /// User-adjustable dot diameter, persisted and clamped.
    static var dot: CGFloat {
        let raw = UserDefaults.standard.object(forKey: Defaults.dotSize) as? Double ?? Double(defaultDot)
        return clampDot(CGFloat(raw))
    }
    static func clampDot(_ v: CGFloat) -> CGFloat { min(max(v, minDot), maxDot) }
    static func setDot(_ v: CGFloat) { UserDefaults.standard.set(Double(clampDot(v)), forKey: Defaults.dotSize) }
    static func resetDot() { UserDefaults.standard.removeObject(forKey: Defaults.dotSize) }

    static func size(count: Int) -> NSSize {
        let n = max(count, 1)
        let w = padH * 2 + CGFloat(n) * dot + CGFloat(n - 1) * gap
        let h = padV * 2 + dot
        return NSSize(width: w, height: h)
    }

    static func dotRect(_ i: Int) -> NSRect {
        NSRect(x: padH + CGFloat(i) * (dot + gap), y: padV, width: dot, height: dot)
    }

    // Frame-mode control dot: fixed default (mid) size, independent of the
    // user's dot-size slider.
    static let controlPad: CGFloat = 6   // glow margin around the control dot
    static func controlSize() -> NSSize {
        NSSize(width: defaultDot + controlPad * 2, height: defaultDot + controlPad * 2)
    }
    static func controlRect() -> NSRect {
        NSRect(x: controlPad, y: controlPad, width: defaultDot, height: defaultDot)
    }
}

/// A horizontal row of dots — one per live session — that reflects each
/// session's state and lets the user click a dot to focus its terminal tab.
final class BadgeView: NSView {
    private var itemLayers: [CALayer] = []
    private(set) var sessions: [(id: String, session: Session)] = []
    private var prevStates: [String: AgentState] = [:]
    private var style: BadgeStyle = .dots
    private var renderedStyle: BadgeStyle = .dots
    weak var controller: BadgeController?

    private var mouseDownPoint: NSPoint = .zero
    private var didDrag = false
    private var trackingArea: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Rendering

    /// Render the badge. Dots/miners → a row of per-session items; frame → a
    /// single control dot tinted with the aggregate color (the real signal is
    /// the screen border drawn by FrameOverlay).
    func render(sessions: [(id: String, session: Session)], style: BadgeStyle, aggregate: AgentState?) {
        self.sessions = sessions
        self.style = style
        let count = (style == .frame) ? 1 : max(sessions.count, 1)

        if itemLayers.count != count || renderedStyle != style {
            itemLayers.forEach { $0.removeFromSuperlayer() }
            itemLayers = (0..<count).map { _ in
                let l = CALayer()
                l.contentsScale = 2
                l.shadowOffset = .zero
                l.shadowRadius = 5
                layer?.addSublayer(l)
                return l
            }
            renderedStyle = style
        }

        let d = (style == .frame) ? Layout.defaultDot : Layout.dot
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.3)
        for (i, l) in itemLayers.enumerated() {
            let rect = (style == .frame) ? Layout.controlRect() : Layout.dotRect(i)
            l.bounds = CGRect(x: 0, y: 0, width: rect.width, height: rect.height)
            l.position = CGPoint(x: rect.midX, y: rect.midY)

            let state: AgentState? = (style == .frame)
                ? aggregate
                : (sessions.isEmpty ? nil : sessions[i].session.state)
            let (color, active) = agentColor(state)

            switch style {
            case .dots, .frame:
                l.contents = nil
                l.cornerRadius = d / 2
                l.backgroundColor = color.cgColor
                l.shadowColor = color.cgColor
                l.shadowOpacity = active ? 0.9 : 0.0
                l.removeAnimation(forKey: "swing")
            case .miners:
                l.cornerRadius = 0
                l.backgroundColor = NSColor.clear.cgColor
                l.shadowOpacity = 0
                l.contents = Self.minerImage(color: color, size: d)
                l.contentsGravity = .resizeAspect
                if state == .working { addSwing(l) } else { l.removeAnimation(forKey: "swing") }
            }
        }
        CATransaction.commit()

        // Chime + pulse when a session transitions into done (any style).
        var anyFinished = false
        for entry in sessions {
            let prev = prevStates[entry.id]
            if prev != nil && prev != .done && entry.session.state == .done {
                anyFinished = true
                if style != .frame,
                   let idx = sessions.firstIndex(where: { $0.id == entry.id }), idx < itemLayers.count {
                    pulse(itemLayers[idx])
                }
            }
        }
        prevStates = Dictionary(sessions.map { ($0.id, $0.session.state) }, uniquingKeysWith: { a, _ in a })
        if anyFinished { controller?.sessionDidFinish() }
    }

    private func addSwing(_ l: CALayer) {
        guard l.animation(forKey: "swing") == nil else { return }
        let a = CABasicAnimation(keyPath: "transform.rotation.z")
        a.fromValue = -0.28
        a.toValue = 0.28
        a.duration = 0.4
        a.autoreverses = true
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        l.add(a, forKey: "swing")
    }

    private func pulse(_ item: CALayer) {
        let anim = CAKeyframeAnimation(keyPath: "transform.scale")
        anim.values = [1.0, 1.6, 1.0]
        anim.keyTimes = [0, 0.4, 1]
        anim.duration = 0.5
        item.add(anim, forKey: "pulse")
    }

    /// A hammer symbol filled with `color`, rendered to a size×size image (@2x).
    private static func minerImage(color: NSColor, size: CGFloat) -> CGImage? {
        let px = max(1, size * 2)
        let cfg = NSImage.SymbolConfiguration(pointSize: px * 0.9, weight: .semibold)
        guard let base = NSImage(systemSymbolName: "hammer.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) else { return nil }
        let out = NSImage(size: NSSize(width: px, height: px), flipped: false) { _ in
            let s = base.size
            base.draw(in: NSRect(x: (px - s.width) / 2, y: (px - s.height) / 2, width: s.width, height: s.height))
            color.set()
            NSRect(x: 0, y: 0, width: px, height: px).fill(using: .sourceAtop)
            return true
        }
        return out.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    // MARK: - Hit testing

    func hitDot(_ pointInView: NSPoint) -> Int? {
        guard style != .frame else { return nil }   // control dot isn't a session
        for i in sessions.indices where Layout.dotRect(i).contains(pointInView) { return i }
        return nil
    }

    // MARK: - Mouse

    private enum DragMode { case none, move, resize }
    private var dragMode: DragMode = .none
    private var startDotSize: CGFloat = Layout.defaultDot

    /// Trailing-edge zone (past the last dot) that triggers resize.
    private func inResizeZone(_ pView: NSPoint) -> Bool {
        pView.x >= bounds.maxX - Layout.resizeGrip
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .mouseEnteredAndExited],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if inResizeZone(p) {
            NSCursor.resizeLeftRight.set()
            controller?.hideTooltip()
            return
        }
        NSCursor.arrow.set()
        if let i = hitDot(p), i < sessions.count {
            let screenPt = window?.convertPoint(toScreen: event.locationInWindow) ?? .zero
            controller?.showTooltip(for: sessions[i].session, at: screenPt)
        } else {
            controller?.hideTooltip()
        }
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
        controller?.hideTooltip()
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = NSEvent.mouseLocation  // screen coords
        didDrag = false
        controller?.hideTooltip()
        // Frame-mode control dot is fixed (top-right); no move/resize.
        if style == .frame { dragMode = .none; return }
        let pView = convert(event.locationInWindow, from: nil)
        if inResizeZone(pView) {
            dragMode = .resize
            startDotSize = Layout.dot
        } else {
            dragMode = .move
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let now = NSEvent.mouseLocation
        let dx = now.x - mouseDownPoint.x
        let dy = now.y - mouseDownPoint.y
        if !didDrag && (abs(dx) + abs(dy) > 3) { didDrag = true }
        guard didDrag else { return }

        if dragMode == .resize {
            // Drag right grows every dot; left shrinks. Cumulative from the
            // press point, so the size tracks the cursor smoothly.
            NSCursor.resizeLeftRight.set()
            Layout.setDot(startDotSize + dx * 0.25)
            controller?.refreshLayout()
            return
        }

        guard let win = window else { return }
        let origin = win.frame.origin
        win.setFrameOrigin(NSPoint(x: origin.x + dx, y: origin.y + dy))
        mouseDownPoint = now
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragMode = .none }
        if dragMode == .resize { return }   // already persisted live
        if didDrag {
            controller?.didDragWindow()
            return
        }
        let p = convert(event.locationInWindow, from: nil)
        if let i = hitDot(p) { controller?.didClickDot(i) }
    }

    override func rightMouseDown(with event: NSEvent) {
        controller?.showMenu(for: event, in: self)
    }
}

/// Owns the floating window, the badge view, and the watcher.
final class BadgeController: NSObject {
    private var window: NSWindow!
    private var badge: BadgeView!
    private var watcher: Watcher!
    private let defaults = UserDefaults.standard
    private let store = SessionStore()
    private lazy var frameOverlay = FrameOverlay()
    // Completion chime; "Glass" is the classic macOS "done" sound.
    private let doneSound = NSSound(named: NSSound.Name("Glass"))

    /// Whether to chime when a session turns green. Defaults to on.
    private var soundEnabled: Bool {
        get { defaults.object(forKey: Defaults.soundEnabled) == nil ? true : defaults.bool(forKey: Defaults.soundEnabled) }
        set { defaults.set(newValue, forKey: Defaults.soundEnabled) }
    }

    /// Called by the badge when any dot transitions to done.
    func sessionDidFinish() {
        guard soundEnabled else { return }
        doneSound?.stop()
        doneSound?.play()
    }

    // MARK: - Hover tooltip

    private lazy var tooltip = TooltipWindow()

    func showTooltip(for s: Session, at screenPoint: NSPoint) {
        tooltip.show(text: tooltipText(s), near: screenPoint)
    }

    func hideTooltip() { tooltip.hide() }

    private func tooltipText(_ s: Session) -> String {
        let proj = (s.cwd as NSString).lastPathComponent
        let head = [s.tool.rawValue, s.state.rawValue, proj.isEmpty ? nil : proj]
            .compactMap { $0 }.joined(separator: " · ")
        if let t = s.title, !t.isEmpty { return head + "\n" + t }
        return head
    }

    func start() {
        let initial = NSRect(origin: .zero, size: Layout.size(count: 1))
        window = NSWindow(contentRect: initial,
                          styleMask: .borderless,
                          backing: .buffered,
                          defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .statusBar
        window.ignoresMouseEvents = false
        window.acceptsMouseMovedEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                     .ignoresCycle, .fullScreenAuxiliary]

        badge = BadgeView(frame: initial)
        badge.controller = self
        window.contentView = badge

        resizeAndPosition(count: 1)
        window.orderFrontRegardless()

        watcher = Watcher { [weak self] list in
            self?.render(list)
        }
        watcher.start()
        render(watcher.current())
    }

    private func render(_ list: [(id: String, session: Session)]) {
        lastList = list
        let style = store.readStyle()
        let aggregate = store.aggregate(now: Date().timeIntervalSince1970)

        if style == .frame {
            frameOverlay.show()
            frameOverlay.update(state: aggregate)
        } else {
            frameOverlay.hide()
        }

        if style == .frame {
            positionControlDot()
        } else {
            resizeAndPosition(count: max(list.count, 1))
        }
        badge.render(sessions: list, style: style, aggregate: aggregate)
    }

    /// Frame mode: pin the control dot to the top-right, 24pt inside the frame,
    /// at the default (mid) size — regardless of the user's corner/size prefs.
    private func positionControlDot() {
        guard let screen = NSScreen.main else { return }
        let f = screen.frame
        let size = Layout.controlSize()
        let gapToFrame: CGFloat = 24
        // Distance from the screen edge to the dot's outer edge:
        let dotInset = FrameOverlay.inset + FrameOverlay.lineWidth + gapToFrame
        let winInset = dotInset - Layout.controlPad   // window edge (dot sits controlPad inside)
        let origin = NSPoint(x: f.maxX - size.width - winInset,
                             y: f.maxY - size.height - winInset)
        window.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private var lastList: [(id: String, session: Session)] = []

    /// Re-render at the current dot size / style (resize grip, style change)
    /// without waiting for the next poll.
    func refreshLayout() { render(lastList) }

    // MARK: - Clicks

    func didClickDot(_ index: Int) {
        guard index < badge.sessions.count else { return }
        TerminalFocus.focus(badge.sessions[index].session)
    }

    func didDragWindow() {
        let o = window.frame.origin
        defaults.set(true, forKey: Defaults.useCustomOrigin)
        defaults.set(Double(o.x), forKey: Defaults.customOriginX)
        defaults.set(Double(o.y), forKey: Defaults.customOriginY)
    }

    // MARK: - Positioning

    /// Margin between the badge and the screen edge.
    private static let screenInset: CGFloat = 16

    private func resizeAndPosition(count: Int) {
        let size = Layout.size(count: count)
        var frame = window.frame
        frame.size = size

        let inset = Self.screenInset
        if defaults.bool(forKey: Defaults.useCustomOrigin) {
            // Keep the dragged origin (row grows rightward/upward).
            frame.origin = NSPoint(x: defaults.double(forKey: Defaults.customOriginX),
                                   y: defaults.double(forKey: Defaults.customOriginY))
        } else if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            let corner = Corner(rawValue: defaults.string(forKey: Defaults.corner) ?? "") ?? .bottomRight
            switch corner {
            case .topLeft:     frame.origin = NSPoint(x: vf.minX + inset, y: vf.maxY - size.height - inset)
            case .topRight:    frame.origin = NSPoint(x: vf.maxX - size.width - inset, y: vf.maxY - size.height - inset)
            case .bottomLeft:  frame.origin = NSPoint(x: vf.minX + inset, y: vf.minY + inset)
            case .bottomRight: frame.origin = NSPoint(x: vf.maxX - size.width - inset, y: vf.minY + inset)
            }
        }

        // Always keep the whole badge inside the visible screen with a margin —
        // so it never pokes under the edge when it appears or grows a new dot.
        if let screen = window.screen ?? NSScreen.main {
            let vf = screen.visibleFrame
            frame.origin.x = min(max(frame.origin.x, vf.minX + inset), vf.maxX - size.width - inset)
            frame.origin.y = min(max(frame.origin.y, vf.minY + inset), vf.maxY - size.height - inset)
        }
        window.setFrame(frame, display: true)
    }

    // MARK: - Menu

    func showMenu(for event: NSEvent, in view: NSView) {
        let menu = NSMenu()
        let header = NSMenuItem(title: "Agent Signaller", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let cornerItem = NSMenuItem(title: "Snap to corner", action: nil, keyEquivalent: "")
        let cornerSub = NSMenu()
        for c in Corner.allCases {
            let it = NSMenuItem(title: c.title, action: #selector(snapCorner(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = c.rawValue
            cornerSub.addItem(it)
        }
        cornerItem.submenu = cornerSub
        menu.addItem(cornerItem)

        let styleItem = NSMenuItem(title: "Style", action: nil, keyEquivalent: "")
        let styleSub = NSMenu()
        let current = store.readStyle()
        for s in BadgeStyle.allCases {
            let it = NSMenuItem(title: s.title, action: #selector(selectStyle(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = s.rawValue
            it.state = (s == current) ? .on : .off
            styleSub.addItem(it)
        }
        styleItem.submenu = styleSub
        menu.addItem(styleItem)

        let resetSize = NSMenuItem(title: "Reset dot size", action: #selector(resetDotSize), keyEquivalent: "")
        resetSize.target = self
        menu.addItem(resetSize)

        let sound = NSMenuItem(title: "Sound when done", action: #selector(toggleSound(_:)), keyEquivalent: "")
        sound.target = self
        sound.state = soundEnabled ? .on : .off
        menu.addItem(sound)

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin(_:)), keyEquivalent: "")
        login.target = self
        login.state = loginEnabled() ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    @objc private func selectStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let s = BadgeStyle(rawValue: raw) else { return }
        store.writeStyle(s)
        refreshLayout()
    }

    @objc private func resetDotSize() {
        Layout.resetDot()
        refreshLayout()
    }

    @objc private func toggleSound(_ sender: NSMenuItem) {
        soundEnabled.toggle()
        if soundEnabled { sessionDidFinish() }  // brief preview when turning on
    }

    @objc private func snapCorner(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        defaults.set(raw, forKey: Defaults.corner)
        defaults.set(false, forKey: Defaults.useCustomOrigin)
        resizeAndPosition(count: max(badge.sessions.count, 1))
    }

    private func loginEnabled() -> Bool {
        if #available(macOS 13.0, *) { return SMAppService.mainApp.status == .enabled }
        return false
    }

    @objc private func toggleLogin(_ sender: NSMenuItem) {
        if #available(macOS 13.0, *) {
            do {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                } else {
                    try SMAppService.mainApp.register()
                }
            } catch {
                NSLog("agent-signaller: login item toggle failed: \(error)")
            }
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

/// A small floating label that shows a session's topic on hover. Custom (not a
/// native NSToolTip) because tooltips are unreliable for a borderless, non-key
/// window in an accessory app.
final class TooltipWindow {
    private let panel: NSWindow
    private let label: NSTextField
    private let pad: CGFloat = 8
    private let maxWidth: CGFloat = 300

    init() {
        label = NSTextField(wrappingLabelWithString: "")
        label.isEditable = false
        label.isSelectable = false
        label.drawsBackground = false
        label.textColor = .white
        label.font = .systemFont(ofSize: 12.5)
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.cell?.truncatesLastVisibleLine = false

        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 0.96).cgColor
        content.layer?.cornerRadius = 6
        content.addSubview(label)

        panel = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.contentView = content
    }

    func show(text: String, near screenPoint: NSPoint) {
        label.stringValue = text
        // Measure the text directly — intrinsicContentSize under-sizes a
        // wrapping label and was clipping the first line.
        let avail = maxWidth - pad * 2
        let opts: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        let measured = (text as NSString).boundingRect(
            with: NSSize(width: avail, height: 2000), options: opts,
            attributes: [.font: label.font as Any])
        let w = min(avail, ceil(measured.width) + 4)   // small fudge to avoid re-wrap
        let h = ceil(measured.height) + 2
        let winSize = NSSize(width: w + pad * 2, height: h + pad * 2)

        var origin = NSPoint(x: screenPoint.x - winSize.width / 2, y: screenPoint.y + 14)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(screenPoint) }) ?? NSScreen.main {
            let vf = screen.visibleFrame
            origin.x = min(max(origin.x, vf.minX + 4), vf.maxX - winSize.width - 4)
            // flip below the cursor if it would run off the top
            if origin.y + winSize.height > vf.maxY - 4 { origin.y = screenPoint.y - winSize.height - 14 }
        }
        panel.setFrame(NSRect(origin: origin, size: winSize), display: true)
        label.frame = NSRect(x: pad, y: pad, width: w, height: h)
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }
}
