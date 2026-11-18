import AppKit

// The interactive parts of the notch (expanded list, cards, reply), in plain AppKit.
// Manual frames, reused views, attributed strings: an update is a few label assignments,
// never a view-tree diff. Mounted only while open; see NotchRootView.

// MARK: - Building blocks

class FlippedView: NSView {
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true } // panel never activates
}

enum UI {
    static func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular, mono: Bool = false, digits: Bool = false) -> NSFont {
        if mono { return .monospacedSystemFont(ofSize: size, weight: weight) }
        if digits { return rounded(size, weight) }
        return .systemFont(ofSize: size, weight: weight)
    }

    /// SF Pro Rounded with fixed-width digits: every number in the notch (timers, diffs, counts)
    /// is one family, and they don't jiggle as they change.
    static func rounded(_ size: CGFloat, _ weight: NSFont.Weight = .semibold) -> NSFont {
        let base = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
    }

    /// Pressed buttons squish a little (around their center) and spring back.
    static func press(_ v: NSView, _ down: Bool) {
        guard let l = v.layer else { return }
        let b = l.bounds
        let scale: CGFloat = down ? 0.93 : 1
        var t = CATransform3DMakeTranslation(b.midX, b.midY, 0)
        t = CATransform3DScale(t, scale, scale, 1)
        t = CATransform3DTranslate(t, -b.midX, -b.midY, 0)
        let s = NotchRootView.spring("transform", damping: down ? 0.9 : 0.55)
        s.fromValue = NSValue(caTransform3D: l.presentation()?.transform ?? l.transform)
        s.toValue = NSValue(caTransform3D: t)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        l.transform = t
        CATransaction.commit()
        l.add(s, forKey: "press")
    }

    static func label(_ font: NSFont, _ color: NSColor = .white, lines: Int = 1) -> NSTextField {
        let l = lines == 1 ? NSTextField(labelWithString: "") : NSTextField(wrappingLabelWithString: "")
        l.font = font
        l.textColor = color
        l.maximumNumberOfLines = lines
        // Truncating-tail forces a single line; multi-line labels must word-wrap and only
        // ellipsize their last visible line.
        l.lineBreakMode = lines == 1 ? .byTruncatingTail : .byWordWrapping
        l.usesSingleLineMode = lines == 1
        l.cell?.truncatesLastVisibleLine = true
        l.isSelectable = false
        return l
    }

    /// SF Symbol tinted and sized to sit inline in text.
    static func symbol(_ name: String, _ size: CGFloat, _ color: NSColor, _ weight: NSFont.Weight = .semibold) -> NSAttributedString {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
            .applying(.init(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return NSAttributedString() }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(x: 0, y: -1, width: image.size.width, height: image.size.height)
        return NSAttributedString(attachment: attachment)
    }

    static func text(_ s: String, _ font: NSFont, _ color: NSColor) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
    }

    /// Width of a label's text (truncating labels report their frame, not their content).
    static func width(_ l: NSTextField) -> CGFloat {
        l.stringValue.isEmpty ? 0 : ceil(l.attributedStringValue.size().width) + 4
    }

    static func height(_ l: NSTextField) -> CGFloat { ceil(l.intrinsicContentSize.height) }
}

/// Capsule button (approve, answers, "Answer in T3 Code", Stop). Closure-based.
final class PillButton: NSButton {
    private let onClick: () -> Void
    var primary: Bool { didSet { restyle() } }
    var destructive = false { didSet { restyle() } }
    private let pillHeight: CGFloat

    init(_ title: String, primary: Bool = false, height: CGFloat = 26, onClick: @escaping () -> Void) {
        self.onClick = onClick
        self.primary = primary
        self.pillHeight = height
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = height / 2
        target = self
        action = #selector(fire)
        setTitle(title)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setTitle(_ title: String) {
        attributedTitle = UI.text(title, UI.font(pillHeight < 24 ? 10 : 11, .semibold), primary ? Theme.current.onAccent : .white)
        restyle()
    }

    private func restyle() {
        layer?.backgroundColor = (destructive ? NSColor.systemRed.withAlphaComponent(0.85)
            : primary ? Theme.current.accent.withAlphaComponent(0.92) : Theme.current.fill(0.1)).cgColor
        if let t = attributedTitle.mutableCopy() as? NSMutableAttributedString, t.length > 0 {
            t.addAttribute(.foregroundColor, value: primary && !destructive ? Theme.current.onAccent : NSColor.white,
                           range: NSRange(location: 0, length: t.length))
            attributedTitle = t
        }
    }

    var fittingWidth: CGFloat { ceil(attributedTitle.size().width) + (pillHeight < 24 ? 16 : 24) }

    override func highlight(_ flag: Bool) { UI.press(self, flag) }

    @objc private func fire() { onClick() }
}

/// Round icon button (open, close, settings, reply, send).
final class IconButton: NSButton {
    private let onClick: () -> Void

    init(_ symbol: String, size: CGFloat = 22, glyph: CGFloat = 10, filled: Bool = true,
         help: String? = nil, onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: CGRect(x: 0, y: 0, width: size, height: size))
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = size / 2
        layer?.backgroundColor = filled ? Theme.current.fill(0.1).cgColor : nil
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)?
            .withSymbolConfiguration(.init(pointSize: glyph, weight: .bold))
        contentTintColor = NSColor.white.withAlphaComponent(0.75)
        imagePosition = .imageOnly
        toolTip = help
        target = self
        action = #selector(fire)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func highlight(_ flag: Bool) { UI.press(self, flag) }
    @objc private func fire() { onClick() }
}

// MARK: - Expanded list

/// Only what's waiting on you (needs you, plan ready, failed, done unread); T3's shelves are
/// counted in the footer. A row opens its thread; the footer opens T3 Code.
@MainActor
final class ExpandedView: FlippedView {
    private let model: NotchModel
    private let store: ThreadStore

    private let heading = UI.label(UI.font(12, .semibold))
    private let note = UI.label(UI.font(10, .medium))
    private lazy var gear = IconButton("gearshape.fill", size: 20, glyph: 11, filled: false, help: "Settings") { [weak self] in
        self?.model.onSettings()
    }
    private let emptyIcon = NSImageView()
    private let empty = UI.label(UI.font(12, .medium), NSColor.white.withAlphaComponent(0.5))
    private var rows: [String: ThreadRowView] = [:]
    private lazy var reply = ReplyBar(model: model, store: store)
    private let hints = KeyHintsView()
    private lazy var footer = ShelfFooter(model: model, store: store)
    private var clock: Timer?
    /// Rows added since the last layout: they fade in where they land instead of sliding.
    private var fresh: Set<String> = []
    /// The first layout cascades the rows in; after that, rows slide to new places.
    private var entered = false
    private var replyFresh = false
    /// The notch shape's damping, so rows and the footer move in step with its edge.
    var damping: CGFloat = 0.78

    init(model: NotchModel, store: ThreadStore) {
        self.model = model
        self.store = store
        super.init(frame: .zero)
        heading.stringValue = "T3 Code"
        emptyIcon.imageScaling = .scaleProportionallyDown
        [heading, note, gear, emptyIcon, empty, hints, footer].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        clock?.invalidate()
        guard window != nil else { return }
        // Relative times: one tick a second while the list is open, nothing otherwise.
        clock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.rows.values.forEach { $0.tick() } }
        }
        clock?.tolerance = 0.2
    }

    func update() {
        if store.incompatible != nil {
            note.stringValue = "Needs an update"
            note.textColor = ThreadStatus.pendingApproval.color
        } else if !store.connected {
            note.stringValue = "Offline · reconnecting"
            note.textColor = NSColor.white.withAlphaComponent(0.45)
        } else {
            note.stringValue = ""
        }

        // Rows: reuse by thread id.
        let threads = model.listThreads
        let ids = Set(threads.map(\.id))
        for (id, row) in rows where !ids.contains(id) {
            rows[id] = nil
            Anim.exit(row, duration: 0.12) { row.removeFromSuperview() } // fades where it was while the rest close up
        }
        for t in threads {
            let row = rows[t.id] ?? {
                let r = ThreadRowView(model: model, store: store)
                addSubview(r)
                rows[t.id] = r
                fresh.insert(t.id)
                return r
            }()
            row.configure(t, selected: model.keyboard && model.selectedThread?.id == t.id)
        }

        let quiet = threads.isEmpty
        empty.isHidden = !quiet
        emptyIcon.isHidden = !quiet || store.incompatible != nil || !store.connected
        if quiet {
            empty.stringValue = store.incompatible ?? (store.connected ? "Nothing needs you" : "T3 Code isn't running")
            emptyIcon.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .medium)
                    .applying(.init(paletteColors: [NSColor.white.withAlphaComponent(0.35)])))
        }

        // Reply field under its row.
        if let id = model.replyingTo, let t = threads.first(where: { $0.id == id }) {
            if reply.superview == nil { addSubview(reply); replyFresh = true }
            reply.configure(t)
        } else if reply.superview != nil {
            reply.removeFromSuperview()
        }

        if hints.isHidden == model.keyboard {
            hints.isHidden = !model.keyboard
            if model.keyboard { Anim.fadeIn(hints) }
        }
        if model.keyboard { hints.show(for: model.selectedThread, replying: model.replyingTo != nil) }
        footer.update()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        let top = model.notchSize.height
        heading.frame = CGRect(x: 32, y: (top - UI.height(heading)) / 2, width: UI.width(heading), height: UI.height(heading))
        note.frame = CGRect(x: heading.frame.maxX + 6, y: (top - UI.height(note)) / 2 + 1, width: UI.width(note), height: UI.height(note))
        gear.frame = CGRect(x: w - 32 - 20, y: (top - 20) / 2, width: 20, height: 20)

        // Opening: the rows cascade in, one a beat after the other. Open: rows slide to their
        // new places on the shape's spring, and new ones fade in where they land.
        let cascade = !entered && window != nil
        var y = model.listTop
        let rowX: CGFloat = 22, rowW = w - 44
        for (i, t) in model.listThreads.enumerated() {
            guard let row = rows[t.id] else { continue }
            let h = model.rowHeight(t)
            let f = CGRect(x: rowX, y: y, width: rowW, height: h)
            if cascade || fresh.contains(t.id) {
                row.frame = f
                Anim.enter(row, delay: cascade ? 0.03 + 0.03 * Double(min(i, 6)) : 0.06, drop: cascade ? 10 : 6)
            } else {
                Anim.glide(row, to: f, damping: damping)
            }
            y += h
            if model.replyingTo == t.id {
                let rf = CGRect(x: rowX, y: y, width: rowW, height: NotchModel.replyHeight)
                if replyFresh {
                    reply.frame = rf
                    Anim.enter(reply, delay: 0.04, drop: 6)
                } else {
                    Anim.glide(reply, to: rf, damping: damping)
                }
                replyFresh = false
                y += NotchModel.replyHeight
            }
        }
        if window != nil { entered = true; fresh = [] }
        // Empty: a quiet check and one line, centered (by frame) in a row's height.
        let ew = UI.width(empty) + 4, eh = UI.height(empty)
        let iconW: CGFloat = emptyIcon.isHidden ? 0 : 20
        let ex = ((w - ew - iconW) / 2).rounded()
        let ey = (model.listTop + (NotchModel.rowHeight - eh) / 2).rounded()
        emptyIcon.frame = CGRect(x: ex, y: ey + (eh - 16) / 2, width: 16, height: 16)
        empty.frame = CGRect(x: ex + iconW, y: ey, width: ew, height: eh)

        let footerTop = model.footerTop
        Anim.glide(hints, to: CGRect(x: 0, y: footerTop - NotchModel.hintsHeight - 2, width: w, height: NotchModel.hintsHeight),
                   damping: damping)
        Anim.glide(footer, to: CGRect(x: rowX, y: footerTop, width: rowW, height: NotchModel.footerHeight), damping: damping)
    }
}

/// "+2 more · ⚡ 5 working · ☾ 2 snoozed · ▣ 14 settled   Open T3 Code ↗", as one button: T3's
/// sidebar shelves, counted, not opened here. Clicking anywhere on it brings T3 Code up.
@MainActor
final class ShelfFooter: FlippedView, PressTarget {
    private let model: NotchModel
    private let store: ThreadStore
    private let divider = CALayer()
    private let plate = CALayer()
    private let counts = RollingLabel()
    private let open = UI.label(UI.font(11, .semibold))
    private var lit: Bool?

    init(model: NotchModel, store: ThreadStore) {
        self.model = model
        self.store = store
        super.init(frame: .zero)
        wantsLayer = true
        divider.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        plate.cornerRadius = 11
        layer?.addSublayer(divider)
        layer?.addSublayer(plate)
        counts.wantsLayer = true
        counts.layer?.masksToBounds = true
        [counts, open].forEach(addSubview)
        toolTip = "Open T3 Code"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) { store.openApp() }

    func update() {
        let s = store.summary
        let dim = NSColor.white.withAlphaComponent(0.45), bright = NSColor.white.withAlphaComponent(0.88)
        let numberFont = UI.rounded(11, .semibold), wordFont = UI.font(11, .medium)
        // Each count rolls on its own; a chip's icon lights up (cross-fades) when it leaves zero.
        var segments: [RollingLabel.Segment] = []
        func chip(_ id: String, _ symbol: String, _ n: Int, _ word: String, tint: NSColor? = nil) {
            if !segments.isEmpty {
                segments.append(.init(id: id + ".dot", text: UI.text("   ·   ", wordFont, NSColor.white.withAlphaComponent(0.2))))
            }
            let lit = n > 0
            let icon = NSMutableAttributedString(attributedString: UI.symbol(symbol, 10, lit ? (tint ?? bright) : dim))
            icon.append(UI.text("  ", numberFont, dim))
            segments.append(.init(id: id + ".icon", text: icon, style: lit ? "lit" : "dim"))
            segments.append(.init(id: id + ".n", text: UI.text("\(n)", numberFont, lit ? bright : dim), number: true))
            segments.append(.init(id: id + ".word", text: UI.text(" " + word, wordFont, dim)))
        }
        let hidden = model.hiddenCount
        if hidden > 0 { chip("more", "ellipsis.circle.fill", hidden, "more", tint: bright) }
        chip("working", "bolt.fill", s.working, "working", tint: ThreadStatus.working.color)
        chip("snoozed", "moon.zzz.fill", s.snoozed, "snoozed")
        chip("settled", "archivebox.fill", s.settled, "settled")
        counts.set(segments)

        let hover = model.hoveredFooter
        let openText = NSMutableAttributedString(attributedString: UI.text("Open T3 Code  ", UI.font(11, .semibold),
                                                                          NSColor.white.withAlphaComponent(hover ? 0.95 : 0.6)))
        openText.append(UI.symbol("arrow.up.forward", 9, NSColor.white.withAlphaComponent(hover ? 0.95 : 0.6), .bold))
        open.attributedStringValue = openText

        // Hover: the plate fades up, like a row.
        let background = (hover ? Theme.current.fill(0.1) : Theme.current.fill(0.045)).cgColor
        if lit != nil, lit != hover {
            let fade = CABasicAnimation(keyPath: "backgroundColor")
            fade.fromValue = plate.presentation()?.backgroundColor ?? plate.backgroundColor
            fade.toValue = background
            fade.duration = hover ? 0.12 : 0.28
            fade.timingFunction = Anim.swap
            plate.add(fade, forKey: "lit")
        }
        lit = hover
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        plate.backgroundColor = background
        CATransaction.commit()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        divider.frame = CGRect(x: 10, y: 0, width: w - 20, height: 1)
        plate.frame = CGRect(x: 0, y: 8, width: w, height: bounds.height - 12)
        CATransaction.commit()
        let mid = plate.frame.midY
        let ow = UI.width(open), oh = UI.height(open)
        open.frame = CGRect(x: w - 14 - ow, y: (mid - oh / 2).rounded(), width: ow, height: oh)
        // Clipped at the side like the label it replaced (truncating), with room above and below
        // for the numbers to roll.
        let ch = counts.fittingHeight + 12
        counts.frame = CGRect(x: 14, y: (mid - ch / 2).rounded(), width: max(0, open.frame.minX - 12 - 14), height: ch)
    }
}

// MARK: - Avatar

/// The provider's logo as pixel art (PixelGlyph). Working: the opencode-style
/// sweep runs over the logo; waiting: a soft band drifts down and up it; needs you: it breathes. Finished,
/// failed and plan-ready keep the logo still with a small status dot in the corner.
@MainActor
final class AvatarView: NSView {
    private let glyph = PixelGlyph()
    private let badge = CALayer()
    private var shown: (String?, ThreadStatus)?

    static let size: CGFloat = 28

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(glyph)
        badge.borderWidth = 1.5
        badge.borderColor = (Theme.current.background ?? .black).cgColor // cuts it out of the logo
        layer?.addSublayer(badge)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let b = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        badge.frame = CGRect(x: b.maxX - 9, y: b.maxY - 9, width: 10, height: 10)
        badge.cornerRadius = 5
        CATransaction.commit()
        glyph.frame = b.insetBy(dx: 4, dy: 4)
    }

    func configure(provider: String?, status: ThreadStatus) {
        if let s = shown, s.0 == provider, s.1 == status { return }
        shown = (provider, status)
        let motion: PixelGlyph.Motion = switch status {
        case .working: .sweep(slow: false)
        case .connecting: .sweep(slow: true)
        case .waiting: .wave
        case .pendingApproval, .awaitingInput, .guestRequest: .breathe
        case .idle: .still(0.6)
        default: .still(1)
        }
        glyph.configure(provider: provider, motion: motion)
        let dot: NSColor? = switch status {
        case .pendingApproval, .awaitingInput, .guestRequest, .failed, .completed, .planReady: status.color
        default: nil
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        badge.isHidden = dot == nil
        badge.backgroundColor = dot?.cgColor
        CATransaction.commit()
    }
}

// MARK: - Thread row

@MainActor
final class ThreadRowView: FlippedView, PressTarget {
    private let model: NotchModel
    private let store: ThreadStore
    private(set) var thread: T3Thread?

    private let title = UI.label(UI.font(13, .semibold))
    private let avatar = AvatarView()
    private let time = UI.label(UI.font(11, .medium, digits: true), NSColor.white.withAlphaComponent(0.55))
    private let meta = UI.label(UI.font(11), NSColor.white.withAlphaComponent(0.5))
    private let diff = RollingLabel()
    private let tools = UI.label(UI.font(11), NSColor.white.withAlphaComponent(0.5))
    private let activity = UI.label(UI.font(11))
    private let terminal = FlippedView()
    private let terminalText = UI.label(UI.font(10, mono: true), NSColor.white.withAlphaComponent(0.75), lines: 4)
    private lazy var replyButton = IconButton("arrowshape.turn.up.left.fill", size: 18, glyph: 9, help: "Reply") { [weak self] in
        guard let self, let t = self.thread else { return }
        self.model.startReply(t)
    }
    private lazy var stop = StopButton(store: store)
    private lazy var actions = RequestActionsView(store: store)

    static let titleHeight: CGFloat = 18

    init(model: NotchModel, store: ThreadStore) {
        self.model = model
        self.store = store
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        terminal.wantsLayer = true
        terminal.layer?.cornerRadius = 8
        terminal.layer?.backgroundColor = Theme.current.fill(0.06).cgColor
        terminal.addSubview(terminalText)
        [avatar, title, replyButton, stop, time, meta, diff, tools, activity, terminal, actions].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    // A removed row fades out where it was: not clickable meanwhile.
    override func hitTest(_ point: NSPoint) -> NSView? { alphaValue == 0 ? nil : super.hitTest(point) }

    // The whole row opens the thread; buttons inside handle their own clicks first.
    override func mouseDown(with event: NSEvent) {
        if let t = thread { store.open(t) }
    }

    private var lit: Bool?

    func configure(_ t: T3Thread, selected: Bool) {
        let previous = thread
        thread = t
        let hover = model.hoveredRow == t.id

        // Hover / selection: the card fades up (instead of snapping) with a hairline on top.
        let on = selected || hover
        let background = on ? Theme.current.fill(selected ? 0.14 : 0.09).cgColor : NSColor.clear.cgColor
        if lit != on, lit != nil, let l = layer {
            let fade = CABasicAnimation(keyPath: "backgroundColor")
            fade.fromValue = l.presentation()?.backgroundColor ?? l.backgroundColor
            fade.toValue = background
            fade.duration = on ? 0.12 : 0.28
            fade.timingFunction = Anim.swap
            l.add(fade, forKey: "lit")
        }
        lit = on
        layer?.backgroundColor = background
        layer?.borderWidth = on ? 1 : 0
        layer?.borderColor = NSColor.white.withAlphaComponent(selected ? 0.18 : 0.07).cgColor

        title.stringValue = t.title
        title.textColor = NSColor.white.withAlphaComponent(t.status == .idle ? 0.7 : 1)
        avatar.configure(provider: t.provider, status: t.status)
        let same = previous?.id == t.id
        // Hover controls fade in rather than blink (going away is instant: the cursor has left).
        show(replyButton, hover && model.replyingTo != t.id, animated: same)
        let busyStop = t.status.isBusy && (hover || store.sending.contains(t.id))
        show(stop, busyStop, animated: same)
        show(time, !busyStop, animated: same)
        if busyStop { stop.configure(t) }

        meta.attributedStringValue = Self.meta(t)
        let d = (t.linesAdded, t.linesRemoved)
        // +N −M: each count rolls digit by digit as the agent edits.
        diff.isHidden = d.0 + d.1 == 0
        let df = UI.font(11, .semibold, digits: true)
        let dt = NSMutableAttributedString(attributedString: UI.text("+\(d.0)", df, Palette.added.withAlphaComponent(0.9)))
        dt.append(UI.text(" −\(d.1)", df, Palette.removed.withAlphaComponent(0.9)))
        diff.set(dt, animated: same)
        let tl = NSMutableAttributedString()
        if diff.isHidden && t.filesChanged > 0 { tl.append(UI.symbol("doc.badge.plus", 9, meta.textColor!)); tl.append(UI.text(" \(t.filesChanged)  ", meta.font!, meta.textColor!)) }
        if t.toolCalls > 0 { tl.append(UI.symbol("hammer", 9, meta.textColor!)); tl.append(UI.text(" \(t.toolCalls)", meta.font!, meta.textColor!)) }
        tools.attributedStringValue = tl

        activity.attributedStringValue = activityText(t)
        let showsOutput = model.showsOutput(t)
        show(terminal, showsOutput, animated: same)
        if showsOutput { terminalText.stringValue = (store.commandOutput[t.id] ?? []).joined(separator: "\n") }
        actions.isHidden = t.request == nil
        if t.request != nil { actions.configure(t) }
        tick()
        needsLayout = true
    }

    private func show(_ v: NSView, _ on: Bool, animated: Bool) {
        guard v.isHidden == on else { return }
        v.isHidden = !on
        if on, animated { Anim.fadeIn(v, duration: 0.16) }
    }

    /// Once a second: relative time / run clock / usage-limit countdown.
    func tick() {
        guard let t = thread else { return }
        let now = Date()
        if t.status.isBusy, let start = t.startedAt {
            let s = max(0, Int(now.timeIntervalSince(start)))
            time.stringValue = String(format: "%d:%02d", s / 60, s % 60)
        } else {
            let s = Int(now.timeIntervalSince(t.updatedAt))
            time.stringValue = s < 60 ? "now" : s < 3600 ? "\(s / 60)m" : s < 86400 ? "\(s / 3600)h" : "\(s / 86400)d"
        }
        if t.usageLimited { activity.attributedStringValue = activityText(t) }
        if !time.isHidden { needsLayout = true }
    }

    private func activityText(_ t: T3Thread) -> NSAttributedString {
        let out = NSMutableAttributedString()
        if t.usageLimited {
            let c = ThreadStatus.pendingApproval.color.withAlphaComponent(0.9)
            out.append(UI.symbol("gauge.with.dots.needle.100percent", 9, c))
            out.append(UI.text("  Usage limit · \(Self.resetText(t.usageLimitResetAt))", UI.font(11), c))
        } else if let a = t.activity {
            let c = t.status.isActive || t.status == .failed
                ? t.status.color.withAlphaComponent(0.85) : NSColor.white.withAlphaComponent(0.4)
            out.append(UI.symbol(t.activityIcon, 9, c))
            out.append(UI.text("  " + a, UI.font(11, mono: t.activityIcon == "terminal"), c))
        }
        return out
    }

    private static func resetText(_ reset: Date?) -> String {
        guard let reset else { return "reset time unknown" }
        let s = Int(reset.timeIntervalSinceNow)
        if s <= 0 { return "ready again" }
        let h = s / 3600, m = (s % 3600 + 59) / 60
        return h > 0 ? "resets in \(h)h \(m)m" : "resets in \(m)m"
    }

    /// project · branch · model · PR badge
    private static func meta(_ t: T3Thread) -> NSAttributedString {
        let f = UI.font(11), c = NSColor.white.withAlphaComponent(0.5)
        let out = NSMutableAttributedString()
        func chip(_ icon: String, _ text: String) {
            if out.length > 0 { out.append(UI.text("   ", f, c)) }
            out.append(UI.symbol(icon, 9, c, .regular))
            out.append(UI.text(" " + text, f, c))
        }
        if !t.project.isEmpty { out.append(UI.text(t.project, f, c)) }
        if let b = t.branch {
            // Branch is the thing you scan for: brighter and a touch heavier than the rest.
            let bright = NSColor.white.withAlphaComponent(0.82)
            if out.length > 0 { out.append(UI.text("   ", f, c)) }
            out.append(UI.symbol("arrow.triangle.branch", 9, bright, .semibold))
            out.append(UI.text(" " + b, UI.font(11, .medium), bright))
        }
        if Settings.showModel, let m = t.model { // the provider's logo is the avatar
            if out.length > 0 { out.append(UI.text("   ", f, c)) }
            out.append(UI.text(m, f, c))
        }
        if let pr = t.pr {
            if out.length > 0 { out.append(UI.text("   ", f, c)) }
            out.append(UI.symbol("arrow.triangle.pull", 10, c, .bold)) // thin at 9pt reads as "‡"
            out.append(UI.text(" " + pr.label, f, c))
            func mark(_ name: String, _ color: NSColor) { out.append(UI.text(" ", f, c)); out.append(UI.symbol(name, 9, color.withAlphaComponent(0.9))) }
            switch pr.checks {
            case .failing?: mark("xmark.circle.fill", .systemRed)
            case .pending?: mark("circle.dotted", .systemYellow)
            case .passing?: mark("checkmark.circle.fill", .systemGreen)
            case nil: break
            }
            switch pr.review {
            case .changesRequested?: mark("exclamationmark.bubble.fill", .systemOrange)
            case .approved?: mark("hand.thumbsup.fill", .systemGreen)
            default: break
            }
            if pr.conflicting { mark("exclamationmark.triangle.fill", .systemOrange) }
        }
        return out
    }

    override func layout() {
        super.layout()
        guard let t = thread else { return }
        let w = bounds.width, pad: CGFloat = 10
        var right = w - pad
        let lineY: (NSTextField, CGFloat) -> CGFloat = { l, h in ((h - UI.height(l)) / 2).rounded() }
        // Avatar beside the first two lines; everything else lines up after it.
        let a = AvatarView.size
        avatar.frame = CGRect(x: pad, y: 8 + ((Self.titleHeight + 3 + UI.height(meta)) - a) / 2, width: a, height: a)
        let left = pad + a + 10

        // Line 1: title ............ [reply] [glyph] [time | stop]
        if !stop.isHidden {
            let sw = stop.fittingWidth
            right -= sw; stop.frame = CGRect(x: right, y: 8, width: sw, height: Self.titleHeight)
        } else {
            let tw = UI.width(time)
            right -= tw; time.frame = CGRect(x: right, y: 8 + lineY(time, Self.titleHeight), width: tw, height: UI.height(time))
        }
        if !replyButton.isHidden { right -= 6 + 24; replyButton.frame = CGRect(x: right, y: 8, width: 24, height: Self.titleHeight) }
        title.frame = CGRect(x: left, y: 8 + lineY(title, Self.titleHeight), width: max(0, right - 8 - left), height: UI.height(title))

        // Line 2: meta, then +N −M and tool counts.
        var x = left
        let y2: CGFloat = 8 + Self.titleHeight + 3
        let mw = min(UI.width(meta), w - left - pad - 120)
        meta.frame = CGRect(x: x, y: y2, width: mw, height: UI.height(meta)); x += mw + 6
        if !diff.isHidden { let dw = diff.fittingWidth; diff.frame = CGRect(x: x, y: y2, width: dw, height: diff.fittingHeight); x += dw + 6 }
        tools.frame = CGRect(x: x, y: y2, width: max(0, min(UI.width(tools), w - pad - x)), height: UI.height(tools))

        // Line 3: activity, then the live terminal and request buttons.
        var y = y2 + UI.height(meta) + 3
        activity.isHidden = activity.attributedStringValue.length == 0
        if !activity.isHidden {
            activity.frame = CGRect(x: left, y: y, width: w - left - pad, height: UI.height(activity))
            y += UI.height(activity) + 6
        }
        if !terminal.isHidden {
            terminal.frame = CGRect(x: left, y: y, width: w - left - pad, height: NotchModel.outputHeight - 8)
            terminalText.frame = terminal.bounds.insetBy(dx: 8, dy: 5)
            y += NotchModel.outputHeight
        }
        if !actions.isHidden, t.request != nil {
            actions.frame = CGRect(x: left, y: y, width: w - left - pad, height: NotchModel.actionBarHeight - 6)
        }
    }
}

/// Two-step stop: first click arms it ("Stop?"), a second within 3s interrupts the run.
@MainActor
final class StopButton: FlippedView {
    private let store: ThreadStore
    private var thread: T3Thread?
    private var armed = false
    private lazy var button = PillButton("Stop", height: 18) { [weak self] in self?.click() }

    init(store: ThreadStore) {
        self.store = store
        super.init(frame: .zero)
        addSubview(button)
    }

    required init?(coder: NSCoder) { fatalError() }

    var fittingWidth: CGFloat { button.fittingWidth + 12 }

    func configure(_ t: T3Thread) {
        thread = t
        let busy = store.sending.contains(t.id)
        button.isEnabled = !busy
        button.destructive = armed
        let label = busy ? "Stopping…" : armed ? "■ Stop?" : "■ Stop"
        if button.attributedTitle.string != label { button.setTitle(label); needsLayout = true }
        button.toolTip = armed ? "Click again to stop this run" : "Stop this run"
    }

    private func click() {
        guard let t = thread else { return }
        if armed {
            store.stop(t)
            armed = false
        } else {
            armed = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.armed else { return }
                self.armed = false
                if let t = self.thread { self.configure(t) }
            }
        }
        configure(t)
    }

    override func layout() {
        super.layout()
        button.frame = bounds
    }
}

// MARK: - Approve / answer

/// Approval options (accept on the right, amber) or one-tap answers; anything richer opens T3.
@MainActor
final class RequestActionsView: FlippedView {
    private let store: ThreadStore
    private var buttons: [PillButton] = []
    private var signature = ""
    private let spinner = NSProgressIndicator()
    private let error = UI.label(UI.font(10), NSColor.systemRed.withAlphaComponent(0.85))

    init(store: ThreadStore) {
        self.store = store
        super.init(frame: .zero)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        addSubview(spinner)
        addSubview(error)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ t: T3Thread) {
        // Rebuild buttons only when the request itself changes.
        var specs: [(String, Bool, () -> Void)] = []
        var sig = t.request?.id ?? ""
        switch t.request?.kind {
        case .approval(_, _, let options)?:
            for o in options.sorted(by: { !$0.isAccept && $1.isAccept }) {
                specs.append((o.label, o.isAccept, { [weak store] in store?.approve(t, o) }))
                sig += o.decision
            }
        default:
            if let q = t.request?.quickQuestion {
                for (i, o) in q.options.enumerated() {
                    specs.append((o.label, i == 0, { [weak store] in store?.answer(t, q, o) }))
                    sig += o.value
                }
            } else {
                specs.append(("Answer in T3 Code", true, { [weak store] in store?.open(t) }))
            }
        }
        if sig != signature {
            signature = sig
            buttons.forEach { $0.removeFromSuperview() }
            buttons = specs.map { PillButton($0.0, primary: $0.1, onClick: $0.2) }
            buttons.forEach(addSubview)
        }
        let busy = store.sending.contains(t.id)
        buttons.forEach { $0.isEnabled = !busy; $0.alphaValue = busy ? 0.5 : 1 }
        busy ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
        error.stringValue = store.failed[t.id] ?? ""
        needsLayout = true
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        for b in buttons {
            let bw = min(b.fittingWidth, max(0, bounds.width - x))
            b.frame = CGRect(x: x, y: 0, width: bw, height: 26)
            x += bw + 6
        }
        spinner.frame = CGRect(x: x + 2, y: 5, width: 16, height: 16)
        error.frame = CGRect(x: 0, y: 28, width: bounds.width, height: UI.height(error))
    }
}

// MARK: - Cards

/// "Needs you": what the agent wants, and buttons to answer right here.
@MainActor
final class NeedsYouView: FlippedView {
    private let model: NotchModel
    private let store: ThreadStore
    private var thread: T3Thread?

    private let pulse = StatusIndicator()
    private let title = UI.label(UI.font(13, .semibold))
    private lazy var openButton = IconButton("arrow.up.forward.app", help: "Open in T3 Code") { [weak self] in
        if let self, let t = self.thread { self.store.open(t) }
    }
    private lazy var closeButton = IconButton("xmark", help: "Hide (still waiting in T3 Code)") { [weak self] in
        self?.store.dismissEvent()
    }
    private let reason = UI.label(UI.font(11))
    private let header = UI.label(UI.font(9, .bold))
    private let body = UI.label(UI.font(12), NSColor.white.withAlphaComponent(0.85), lines: 3)
    private let codeBox = FlippedView()
    private let code = UI.label(UI.font(11, mono: true), NSColor.white.withAlphaComponent(0.8), lines: 3)
    private lazy var actions = RequestActionsView(store: store)

    init(model: NotchModel, store: ThreadStore) {
        self.model = model
        self.store = store
        super.init(frame: .zero)
        codeBox.wantsLayer = true
        codeBox.layer?.cornerRadius = 8
        codeBox.layer?.backgroundColor = Theme.current.fill(0.07).cgColor
        codeBox.addSubview(code)
        [pulse, title, openButton, closeButton, reason, header, body, codeBox, actions].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ t: T3Thread) {
        thread = t
        pulse.show(t.status, small: false)
        title.stringValue = t.title
        let tint = t.status.color.withAlphaComponent(0.9)
        reason.isHidden = true; header.isHidden = true; body.isHidden = true; codeBox.isHidden = true
        switch t.request?.kind {
        case .approval(let prompt, let why, _)?:
            if let why { reason.stringValue = why; reason.textColor = tint; reason.isHidden = false }
            if let prompt { code.stringValue = prompt; codeBox.isHidden = false }
        case .questions(let qs)?:
            if let q = qs.first {
                if !q.header.isEmpty { header.stringValue = q.header.uppercased(); header.textColor = tint; header.isHidden = false }
                body.stringValue = Layout.questionText(qs)
                body.isHidden = false
            }
        case nil:
            body.stringValue = t.activity ?? "Waiting for your input"
            body.isHidden = false
        }
        actions.configure(t)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let t = thread else { return }
        let w = bounds.width, pad = model.sideInset(for: .peek)
        let m = Layout.card(t, width: w, top: model.notchSize.height, inset: pad, error: store.failed[t.id] != nil)
        let inner = w - pad * 2
        var y = model.notchSize.height + 10
        pulse.frame = CGRect(x: pad - 2, y: y + 2, width: 18, height: 18)
        closeButton.frame = CGRect(x: w - pad - 22, y: y, width: 22, height: 22)
        openButton.frame = CGRect(x: closeButton.frame.minX - 8 - 22, y: y, width: 22, height: 22)
        title.frame = CGRect(x: pad + 24, y: y + 2, width: max(0, openButton.frame.minX - 8 - pad - 24), height: UI.height(title))
        y += 22 + 10
        if !reason.isHidden { reason.frame = CGRect(x: pad, y: y, width: inner, height: m.reason); y += m.reason + 6 }
        if !header.isHidden { header.frame = CGRect(x: pad, y: y, width: inner, height: m.header); y += m.header + 3 }
        if !body.isHidden { body.frame = CGRect(x: pad, y: y, width: inner, height: m.body); y += m.body + 10 }
        if !codeBox.isHidden {
            codeBox.frame = CGRect(x: pad, y: y, width: inner, height: m.code)
            code.frame = codeBox.bounds.insetBy(dx: 8, dy: 8)
        }
        actions.frame = CGRect(x: pad, y: m.actionsY, width: inner, height: 44)
    }
}

/// A thread just finished (or failed): its final message, for a few seconds. Click to open.
@MainActor
final class FinishedView: FlippedView, PressTarget {
    private let model: NotchModel
    private let store: ThreadStore
    private var thread: T3Thread?
    private let glyph = StatusIndicator()
    private let badge = CheckBadge()
    private let title = UI.label(UI.font(13, .semibold))
    private let status = UI.label(UI.font(11, .medium))
    private let message = UI.label(UI.font(12), NSColor.white.withAlphaComponent(0.7), lines: 3)

    init(model: NotchModel, store: ThreadStore) {
        self.model = model
        self.store = store
        super.init(frame: .zero)
        [glyph, badge, title, status, message].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        if let t = thread { store.open(t) }
    }

    /// Settled: the check turns into a box, and "Done" into "Settled", once.
    private var settling = false
    private var settledShown = false

    func configure(_ t: T3Thread) {
        thread = t
        let shown: ThreadStatus = t.status == .idle ? .completed : t.status
        let drawn = shown == .completed || shown == .failed
        glyph.isHidden = drawn
        badge.isHidden = !drawn
        if settling, !store.eventSettled {
            // The same thread finished again in this card, and this finish doesn't settle.
            settling = false
            settledShown = false
            badge.reset()
        }
        if drawn { badge.draw(failed: shown == .failed) } else { glyph.show(shown, small: false) }
        title.stringValue = t.title
        if settledShown {
            status.stringValue = "Settled"
            status.textColor = NSColor.white.withAlphaComponent(0.5)
        } else {
            status.stringValue = t.status == .idle ? "Done" : t.status.label
            status.textColor = t.status == .idle ? NSColor.white.withAlphaComponent(0.5) : t.status.color
        }
        message.stringValue = Layout.finishedText(t)
        if store.eventSettled, !settling { settle() } // the store closes this card early
        needsLayout = true
    }

    /// Put away in T3 (an agent merged its own PR): after the check has had its moment, it
    /// drops into a box, and the label crossfades to "Settled".
    private func settle() {
        settling = true
        let delay = badge.settle()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, self.store.eventSettled else { return }
            self.settledShown = true
            self.status.wantsLayer = true
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.25
            self.status.layer?.add(fade, forKey: "settle")
            if let t = self.thread { self.configure(t) }
        }
    }

    override func layout() {
        super.layout()
        guard let t = thread else { return }
        let w = bounds.width, pad = model.sideInset(for: .peek)
        let m = Layout.finished(t, width: w, top: model.notchSize.height, inset: pad)
        let y = model.notchSize.height + 10
        glyph.frame = CGRect(x: pad - 2, y: y + 1, width: 18, height: 18)
        badge.frame = CGRect(x: pad - 1, y: y + 1, width: 18, height: 18)
        let sw = UI.width(status)
        status.frame = CGRect(x: w - pad - sw, y: y + 2, width: sw, height: UI.height(status))
        title.frame = CGRect(x: pad + 26, y: y, width: max(0, status.frame.minX - 8 - pad - 26), height: UI.height(title))
        message.frame = CGRect(x: pad + 26, y: y + 24, width: w - pad * 2 - 28, height: m.message)
    }
}

/// A circle that draws itself, then a check (or a cross) inside it: the finish moment.
@MainActor
final class CheckBadge: NSView {
    private let circle = CAShapeLayer()
    private let mark = CAShapeLayer()
    private let box = CALayer()
    private var drawnFailed: Bool?
    private var drawnAt: CFTimeInterval = 0
    /// From the check starting to draw to the box dropping in. The store times the card by it.
    static let settleSwap = 1.15 + 0.12

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for l in [circle, mark] {
            l.fillColor = nil
            l.lineWidth = 1.8
            l.lineCap = .round
            l.lineJoin = .round
            layer?.addSublayer(l)
        }
        box.opacity = 0
        box.contentsGravity = .resizeAspect
        layer?.addSublayer(box)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// Back to an undrawn check, so the next `draw` draws it fresh.
    func reset() {
        drawnFailed = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in [circle, mark, box] { l.removeAllAnimations() }
        circle.opacity = 1
        mark.opacity = 1
        box.opacity = 0
        CATransaction.commit()
    }

    /// The check shrinks away and an archive box drops into its place with a small bounce.
    /// Waits for the check to finish drawing and sit for a beat; returns the delay until the
    /// swap, so the label can change with it.
    func settle() -> Double {
        let now = CACurrentMediaTime()
        let at = max(now + 0.05, drawnAt + Self.settleSwap - 0.12)
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if let image = NSImage(systemSymbolName: "archivebox.fill", accessibilityDescription: "Settled")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
                .applying(.init(paletteColors: [NSColor.white.withAlphaComponent(0.75)]))) {
            let scale = window?.backingScaleFactor ?? 2
            box.contents = image.layerContents(forContentsScale: scale)
            box.contentsScale = scale
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in [circle, mark] { l.opacity = 0 }
        box.opacity = 1
        CATransaction.commit()

        let out = CAAnimationGroup()
        let shrink = CABasicAnimation(keyPath: "transform.scale")
        shrink.fromValue = 1; shrink.toValue = reduce ? 1 : 0.5
        let fadeOut = CABasicAnimation(keyPath: "opacity")
        fadeOut.fromValue = 1; fadeOut.toValue = 0
        out.animations = [shrink, fadeOut]
        out.duration = 0.18
        shrink.duration = out.duration
        fadeOut.duration = out.duration
        out.timingFunction = CAMediaTimingFunction(name: .easeIn)
        out.beginTime = at
        out.fillMode = .backwards
        for l in [circle, mark] { l.add(out, forKey: "settle") }

        let fadeIn = CABasicAnimation(keyPath: "opacity")
        fadeIn.fromValue = 0; fadeIn.toValue = 1
        fadeIn.duration = 0.14
        var group: [CAAnimation] = [fadeIn]
        if !reduce {
            // Falls in from above and lands with a little squash, like it's been dropped in.
            let drop = CASpringAnimation(keyPath: "transform.translation.y")
            drop.fromValue = -7; drop.toValue = 0
            drop.mass = 1; drop.stiffness = 420; drop.damping = 15
            drop.duration = drop.settlingDuration
            let squash = CAKeyframeAnimation(keyPath: "transform.scale.y")
            squash.values = [1.1, 1.1, 0.86, 1.04, 1]
            squash.keyTimes = [0, 0.3, 0.45, 0.7, 1]
            squash.duration = 0.45
            group += [drop, squash]
        }
        let into = CAAnimationGroup()
        into.animations = group
        into.duration = group.map { $0.duration }.max() ?? 0.14
        into.beginTime = at + 0.12
        into.fillMode = .backwards
        box.add(into, forKey: "settle")
        return at + 0.12 - now
    }

    func draw(failed: Bool) {
        guard drawnFailed != failed else { return }
        drawnFailed = failed
        needsLayout = true
        layoutSubtreeIfNeeded()
        let color = (failed ? ThreadStatus.failed : ThreadStatus.completed).color.cgColor
        let now = CACurrentMediaTime()
        drawnAt = now
        for (l, delay, duration) in [(circle, 0.1, 0.38), (mark, 0.38, 0.26)] {
            l.strokeColor = color
            let a = CABasicAnimation(keyPath: "strokeEnd")
            a.fromValue = 0
            a.toValue = 1
            a.beginTime = now + delay
            a.duration = duration
            a.fillMode = .backwards
            a.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
            l.add(a, forKey: "draw")
        }
    }

    override func layout() {
        super.layout()
        let b = bounds.insetBy(dx: 1.5, dy: 1.5)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        circle.frame = bounds
        mark.frame = bounds
        box.frame = bounds.insetBy(dx: 0, dy: 1)
        // Start at the top and go clockwise, like a ring filling up.
        let ring = CGMutablePath()
        ring.addArc(center: CGPoint(x: b.midX, y: b.midY), radius: b.width / 2,
                    startAngle: -.pi / 2, endAngle: 1.5 * .pi, clockwise: false)
        circle.path = ring
        let m = CGMutablePath()
        let (x, y, s) = (b.minX, b.minY, b.width)
        if drawnFailed == true {
            m.move(to: CGPoint(x: x + s * 0.34, y: y + s * 0.34)); m.addLine(to: CGPoint(x: x + s * 0.66, y: y + s * 0.66))
            m.move(to: CGPoint(x: x + s * 0.66, y: y + s * 0.34)); m.addLine(to: CGPoint(x: x + s * 0.34, y: y + s * 0.66))
        } else {
            m.move(to: CGPoint(x: x + s * 0.28, y: y + s * 0.52))
            m.addLine(to: CGPoint(x: x + s * 0.44, y: y + s * 0.67))
            m.addLine(to: CGPoint(x: x + s * 0.72, y: y + s * 0.36))
        }
        mark.path = m
        CATransaction.commit()
    }
}

// MARK: - Reply

@MainActor
final class ReplyBar: FlippedView, NSTextFieldDelegate {
    private let model: NotchModel
    private let store: ThreadStore
    private let field = NSTextField()
    private let box = FlippedView()
    private let icon = NSImageView()
    private lazy var send = IconButton("arrow.up", size: 22, glyph: 10, help: "Send") { [weak self] in
        self?.model.sendReply()
    }
    private var focusedOnce = false

    init(model: NotchModel, store: ThreadStore) {
        self.model = model
        self.store = store
        super.init(frame: .zero)
        box.wantsLayer = true
        box.layer?.cornerRadius = 10
        box.layer?.backgroundColor = Theme.current.fill(0.08).cgColor
        icon.image = NSImage(systemSymbolName: "arrowshape.turn.up.left.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .bold))
        icon.contentTintColor = NSColor.white.withAlphaComponent(0.4)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = UI.font(12)
        field.textColor = .white
        field.delegate = self
        field.target = self
        field.action = #selector(submit) // Return
        addSubview(box)
        [icon, field, send].forEach(box.addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ t: T3Thread) {
        let hint = t.status.isBusy ? "Steer \(t.title)…" : "Reply to \(t.title)…"
        field.placeholderAttributedString = UI.text(hint, UI.font(12), NSColor.white.withAlphaComponent(0.35))
        if field.stringValue != model.draft { field.stringValue = model.draft }
        let empty = model.draft.trimmingCharacters(in: .whitespaces).isEmpty
        send.layer?.backgroundColor = (empty ? Theme.current.fill(0.12) : Theme.current.accent).cgColor
        send.contentTintColor = empty ? NSColor.white.withAlphaComponent(0.4) : Theme.current.onAccent
        send.isEnabled = !empty
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { focusedOnce = false; return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.focusedOnce else { return }
            self.focusedOnce = true
            self.window?.makeFirstResponder(self.field)
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        model.draft = field.stringValue
    }

    @objc private func submit() { model.sendReply() }

    override func layout() {
        super.layout()
        box.frame = CGRect(x: 10, y: 5, width: bounds.width - 20, height: 34)
        icon.frame = CGRect(x: 12, y: 10, width: 14, height: 14)
        send.frame = CGRect(x: box.bounds.width - 6 - 22, y: 6, width: 22, height: 22)
        let fh = ceil(field.intrinsicContentSize.height)
        field.frame = CGRect(x: 34, y: (34 - fh) / 2, width: send.frame.minX - 8 - 34, height: fh)
    }
}

/// "↑↓ select · ⏎ open · R reply · …" while in keyboard mode.
@MainActor
final class KeyHintsView: FlippedView {
    private var signature = ""
    private var items: [NSView] = []

    func show(for thread: T3Thread?, replying: Bool) {
        var hints: [(String, String)]
        if replying {
            hints = [("⏎", "send"), ("esc", "cancel")]
        } else {
            hints = [("↑↓", "select"), ("⏎", "open"), ("R", "reply")]
            if case .approval? = thread?.request?.kind { hints += [("A", "approve"), ("D", "deny")] }
            if thread?.request?.quickQuestion != nil { hints.append(("1-9", "answer")) }
            hints.append(("esc", "close"))
        }
        let sig = hints.map { $0.0 + $0.1 }.joined()
        guard sig != signature else { return }
        signature = sig
        items.forEach { $0.removeFromSuperview() }
        items = hints.flatMap { key, text -> [NSView] in
            let cap = UI.label(UI.font(9, .semibold), NSColor.white.withAlphaComponent(0.7))
            cap.stringValue = key
            cap.alignment = .center
            cap.wantsLayer = true
            cap.layer?.cornerRadius = 4
            cap.layer?.backgroundColor = Theme.current.fill(0.12).cgColor
            let label = UI.label(UI.font(10), NSColor.white.withAlphaComponent(0.4))
            label.stringValue = text
            return [cap, label]
        }
        items.forEach(addSubview)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        var widths: [CGFloat] = []
        for (i, v) in items.enumerated() {
            guard let l = v as? NSTextField else { continue }
            widths.append(i % 2 == 0 ? UI.width(l) + 6 : UI.width(l))
        }
        let total = widths.enumerated().reduce(CGFloat(0)) { $0 + $1.element + ($1.offset % 2 == 0 ? 4 : 12) } - 12
        var x = ((bounds.width - total) / 2).rounded()
        for (i, v) in items.enumerated() {
            let w = widths[i]
            let h: CGFloat = i % 2 == 0 ? 16 : UI.height(v as! NSTextField)
            v.frame = CGRect(x: x, y: ((bounds.height - h) / 2).rounded(), width: w, height: h)
            x += w + (i % 2 == 0 ? 4 : 12)
        }
    }
}

// MARK: - Provider logos

/// T3 Code's own provider logos (Resources/Logos, from scripts/extract-logos.py), drawn inline.
enum Logos {
    private static var cache: [String: NSImage] = [:]

    static func image(for provider: String?) -> NSImage? {
        guard let provider else { return nil }
        if let hit = cache[provider] { return hit }
        guard let url = Bundle.main.url(forResource: provider, withExtension: "svg", subdirectory: "Logos"),
              let image = NSImage(contentsOf: url) else { return nil }
        cache[provider] = image
        return image
    }

    static func attachment(for provider: String?, height: CGFloat) -> NSAttributedString? {
        guard let image = image(for: provider), image.size.height > 0 else { return nil }
        let a = NSTextAttachment()
        a.image = image
        let width = height * image.size.width / image.size.height
        a.bounds = CGRect(x: 0, y: -2, width: width, height: height)
        return NSAttributedString(attachment: a)
    }
}

/// User preferences (the Settings window).
enum Settings {
    private static func flag(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? value
    }

    // Pop-ups: what drops down from the notch on its own. The list and the pill still count
    // these threads either way.
    /// A finished run's final message, for a few seconds.
    static var popDone: Bool {
        get { flag("popDone", default: true) }
        set { UserDefaults.standard.set(newValue, forKey: "popDone") }
    }
    /// A failed run's last message, for a few seconds.
    static var popFailed: Bool {
        get { flag("popFailed", default: true) }
        set { UserDefaults.standard.set(newValue, forKey: "popFailed") }
    }
    /// The approval / question card, until it's answered.
    static var popNeedsYou: Bool {
        get { flag("popNeedsYou", default: true) }
        set { UserDefaults.standard.set(newValue, forKey: "popNeedsYou") }
    }

    /// Which events make a sound (all of them need `Chime.enabled` too).
    enum SoundEvent: String, CaseIterable {
        case done, failed, needsYou, pullRequest, limitReset
    }
    static func sound(_ e: SoundEvent) -> Bool { flag("sound." + e.rawValue, default: true) }
    static func setSound(_ e: SoundEvent, _ on: Bool) { UserDefaults.standard.set(on, forKey: "sound." + e.rawValue) }

    /// When agents are working and something also waits on you, what's waiting sits on the
    /// right (default: the spinner and "6 working" keep the left), or on the left.
    private static let needsYouOnLeftKey = "needsYouOnLeft"
    static var needsYouOnLeft: Bool {
        get { UserDefaults.standard.object(forKey: needsYouOnLeftKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: needsYouOnLeftKey) }
    }

    private static let showModelKey = "showModel"
    static var showModel: Bool {
        get { UserDefaults.standard.bool(forKey: showModelKey) }
        set { UserDefaults.standard.set(newValue, forKey: showModelKey) }
    }

    /// The open notch glows in the theme's accent (off by default), or casts a plain dark shadow.
    private static let accentGlowKey = "accentGlow"
    static var accentGlow: Bool {
        get { UserDefaults.standard.bool(forKey: accentGlowKey) }
        set { UserDefaults.standard.set(newValue, forKey: accentGlowKey) }
    }

    /// Hovering the notch opens the list (off by default: clicking it does).
    private static let openOnHoverKey = "openOnHover"
    static var openOnHover: Bool {
        get { UserDefaults.standard.object(forKey: openOnHoverKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: openOnHoverKey) }
    }

    /// Hidden from screen sharing, recordings and screenshots (default), or visible in them.
    /// `T3NOTCH_ALLOW_CAPTURE=1` forces visible for one launch without changing the setting.
    private static let hideFromCaptureKey = "hideFromCapture"
    static var hideFromCapture: Bool {
        get {
            if ProcessInfo.processInfo.environment["T3NOTCH_ALLOW_CAPTURE"] != nil { return false }
            return UserDefaults.standard.object(forKey: hideFromCaptureKey) as? Bool ?? true
        }
        set { UserDefaults.standard.set(newValue, forKey: hideFromCaptureKey) }
    }
}
