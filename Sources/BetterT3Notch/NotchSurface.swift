import AppKit

/// The notch, in AppKit + Core Animation (no SwiftUI anywhere).
///
/// SwiftUI re-laid out its whole view tree for every animation frame and every state change,
/// which was ~95% of the app's CPU while threads were working. Here the notch shape is a
/// CAShapeLayer and every label is a plain NSTextField: springs, slides, glows and rolling
/// digits are CAAnimations that run in the window server, so the app does no work per frame.
///
/// The expanded list and cards (NotchContent.swift) only exist while open.
@MainActor
final class NotchRootView: NSView {
    private let model: NotchModel
    private let store: ThreadStore
    private let shape = CAShapeLayer()
    /// The theme's background over the black shape, clipped to it (same springs). With a camera
    /// notch it stays black around the camera and eases into the theme color over the whole panel
    /// (a short fade read as a black band stuck on top).
    private let backdrop = CAGradientLayer()
    private let backdropMask = CAShapeLayer()
    /// Soft light under the edge: pulsing behind a "needs you" card, a flash of green (or red)
    /// when a run ends.
    private let aura = CAShapeLayer()
    /// Depth over the black, clipped to the shape: a faint top-to-bottom sheen, a 1pt inner rim
    /// that fades in below the screen edge, and a light sweeping along the bottom when a run ends.
    private let chrome = CALayer()
    private let chromeMask = CAShapeLayer()
    private let sheen = CAGradientLayer()
    private let rim = CAShapeLayer()
    private let rimFade = CAGradientLayer()
    private let sweepTrack = CALayer()
    private let sweep = CAGradientLayer()
    private let pill: StatusPill
    /// Clips the collapsed pill to the springing shape, so its text never shows past the edge
    /// while it grows or shrinks.
    private let pillMask = CAShapeLayer()
    private var content: NSView?
    private var contentKey = ""
    private var applied: (mode: NotchMode, size: CGSize)?
    private var auraKey = ""

    /// Response 0.42s, damping fraction 0.78: settles fast with a small overshoot.
    /// A finished card opens bouncier (0.6): a little squash-and-settle.
    nonisolated static func spring(_ keyPath: String, damping: CGFloat = 0.78) -> CASpringAnimation {
        Anim.spring(keyPath, response: 0.42, damping: damping)
    }

    /// The damping of the shape's latest spring, so things inside move in step with it.
    private var damping: CGFloat = 0.78

    init(model: NotchModel, store: ThreadStore) {
        self.model = model
        self.store = store
        pill = StatusPill(model: model, store: store)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false

        aura.fillColor = NSColor.black.cgColor
        aura.shadowOpacity = 0
        aura.shadowRadius = 9
        aura.shadowOffset = CGSize(width: 0, height: 2)
        layer?.addSublayer(aura)

        shape.fillColor = NSColor.black.cgColor
        shape.shadowColor = Theme.current.glowColor
        shape.shadowOpacity = 0
        shape.shadowRadius = 14
        shape.shadowOffset = CGSize(width: 0, height: 6)
        layer?.addSublayer(shape)
        if let color = Theme.current.background?.cgColor {
            backdrop.colors = model.hardwareNotch ? Self.easedFade(to: color) : [color, color]
            backdrop.mask = backdropMask
            layer?.addSublayer(backdrop)
        }

        chrome.mask = chromeMask
        sheen.colors = [NSColor.white.withAlphaComponent(0).cgColor, NSColor.white.withAlphaComponent(0.055).cgColor]
        rim.fillColor = nil
        rim.lineWidth = 2 // half of it is outside the shape and clipped: a 1pt inner hairline
        rim.strokeColor = (Theme.current.surface == nil ? NSColor.white.withAlphaComponent(0.12)
                                                       : Theme.current.accent.withAlphaComponent(0.25)).cgColor
        rimFade.colors = [NSColor.clear.cgColor, NSColor.clear.cgColor, NSColor.white.cgColor, NSColor.white.cgColor]
        rim.mask = rimFade
        sweepTrack.masksToBounds = true
        sweep.startPoint = CGPoint(x: 0, y: 0.5)
        sweep.endPoint = CGPoint(x: 1, y: 0.5)
        sweep.frame = CGRect(x: -Self.sweepWidth, y: 0, width: Self.sweepWidth, height: Self.sweepHeight)
        sweepTrack.addSublayer(sweep)
        [sheen, rim, sweepTrack].forEach(chrome.addSublayer)
        layer?.addSublayer(chrome)

        addSubview(pill)
        pill.wantsLayer = true
        pill.layer?.mask = pillMask
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true } // top-left origin
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Clicking the collapsed notch opens the list (hovering only does with "Open on Hover").
    override func mouseDown(with event: NSEvent) {
        let mode = model.mode
        guard mode == .activity || mode == .idle else { return }
        let p = convert(event.locationInWindow, from: nil)
        let s = model.size
        guard CGRect(x: (bounds.width - s.width) / 2, y: 0, width: s.width, height: s.height).insetBy(dx: -4, dy: -4).contains(p)
        else { return }
        model.hovering = true
    }

    override func layout() {
        super.layout()
        applied = nil // canvas changed: re-place everything without animating
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in [backdrop, backdropMask, chrome, chromeMask, sheen, rim, rimFade] { l.frame = bounds }
        backdropMask.frame = backdrop.bounds
        // The rim is invisible where the shape meets the screen edge, and fades in toward its sides.
        let h = max(bounds.height, 1), nh = model.notchSize.height
        rimFade.locations = [0, NSNumber(value: Double(nh * 0.3 / h)), NSNumber(value: Double((nh - 6) / h)), 1]
        CATransaction.commit()
        fadeBackdrop(to: model.size)
        refresh(animated: false)
    }

    /// Called on any model/store change. Cheap when nothing visible changed.
    func refresh(animated: Bool = true) {
        let mode = model.mode
        let size = model.size
        // Where the black shape is *right now* (mid-spring), before it's retargeted.
        var shapeFrom: CGPath?
        var damping: CGFloat = 0.78
        if applied?.mode != mode || applied?.size != size {
            let animate = animated && applied != nil
            if animate { shapeFrom = shape.presentation()?.path ?? shape.path }
            let finishing = mode == .peek && applied?.mode != .peek && store.event?.status.needsYou == false
            // Shrinking settles without overshoot: an underdamped spring dipped below the pill
            // (showing the bare camera notch) before springing back out.
            let shrinking = applied.map { size.width < $0.size.width || size.height < $0.size.height } ?? false
            // Any shrink wins over the finish's bounce (closing the list onto a finished card too).
            damping = shrinking ? 1 : finishing ? 0.6 : 0.78
            self.damping = damping
            setShape(size: size, animated: animate, damping: damping)
            applied = (mode, size)
        }
        syncContent(mode: mode, size: size, shapeFrom: shapeFrom, damping: damping)
        // The pill spans the whole canvas, so its parts can glide with the shape's edges.
        pill.frame = CGRect(x: 0, y: 0, width: bounds.width, height: model.notchSize.height)
        pill.setVisible(mode == .activity)
        if mode == .activity { pill.update(width: size.width, damping: self.damping) }
        syncAura(mode: mode)
    }

    // MARK: Shape

    private func path(for size: CGSize) -> CGPath {
        NotchShape.path(size: size, topRadius: model.topRadius, bottomRadius: model.bottomRadius,
                        offsetX: (bounds.width - size.width) / 2)
    }

    private static let fadeSteps = 8

    /// Black → theme color with ease-in-out stops, so there's no visible edge where it starts.
    private static func easedFade(to color: CGColor) -> [CGColor] {
        let target = NSColor(cgColor: color) ?? .black
        return (0...fadeSteps).map { i in
            let t = CGFloat(i) / CGFloat(fadeSteps)
            let eased = t * t * (3 - 2 * t)
            return (NSColor.black.blended(withFraction: eased, of: target) ?? target).cgColor
        }
    }

    /// Fade from the bottom of the camera notch to the bottom of the shape at `size`.
    private func fadeBackdrop(to size: CGSize) {
        guard model.hardwareNotch, backdrop.superlayer != nil, bounds.height > 0 else { return }
        let start = model.notchSize.height / bounds.height
        let end = max(start + 0.01, min(1, size.height / bounds.height))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop.locations = (0...Self.fadeSteps).map {
            NSNumber(value: Double(start + (end - start) * CGFloat($0) / CGFloat(Self.fadeSteps)))
        }
        CATransaction.commit()
    }

    private func sheenLocations(_ size: CGSize) -> [NSNumber] {
        [0, NSNumber(value: Double(max(size.height, 1) / max(bounds.height, 1)))]
    }

    private func setShape(size: CGSize, animated: Bool, damping: CGFloat) {
        fadeBackdrop(to: size)
        let newPath = path(for: size)
        let expanded = model.mode == .expanded
        // Collapsed beside a camera notch, the pill is plain black like the notch it extends: no
        // sheen, no rim. In a fullscreen app the strip around the notch is black too, and the rim
        // drew an outline around the pill while the sheen made it lighter than the notch.
        let collapsed = model.mode == .idle || model.mode == .activity
        let chromeOpacity: Float = collapsed && model.hardwareNotch ? 0 : 1
        if animated {
            let from = shape.presentation()?.path ?? shape.path
            // Everything shaped like the notch springs together, so nothing peeks out mid-flight.
            let shaped: [(CALayer, String)] = [(shape, "path"), (backdropMask, "path"), (chromeMask, "path"),
                                               (rim, "path"), (aura, "path"), (aura, "shadowPath")]
            for (l, key) in shaped {
                let spring = Self.spring(key, damping: damping)
                spring.fromValue = from
                spring.toValue = newPath
                l.add(spring, forKey: key)
            }
            // Same spring for the pill's clip (the pill spans the canvas: same coordinates).
            let clip = Self.spring("path", damping: damping)
            clip.fromValue = pillMask.presentation()?.path ?? from
            clip.toValue = newPath
            pillMask.add(clip, forKey: "path")
            let sheenSpring = Self.spring("locations", damping: damping)
            sheenSpring.fromValue = sheen.presentation()?.locations ?? sheen.locations
            sheenSpring.toValue = sheenLocations(size)
            sheen.add(sheenSpring, forKey: "locations")
            // The shadow's outline springs with the shape (otherwise it pops to the final size
            // before the notch has opened), and it only fades in once the shape is mostly grown.
            let shadowShape = Self.spring("shadowPath", damping: damping)
            shadowShape.fromValue = shape.presentation()?.shadowPath ?? from
            shadowShape.toValue = newPath
            shape.add(shadowShape, forKey: "shadowPath")
            let fade = CABasicAnimation(keyPath: "shadowOpacity")
            fade.fromValue = shape.presentation()?.shadowOpacity ?? shape.shadowOpacity
            fade.toValue = expanded ? Theme.current.glowOpacity : 0
            fade.duration = expanded ? 0.26 : 0.12
            fade.timingFunction = expanded ? Anim.arrive : Anim.leave
            if expanded {
                fade.beginTime = CACurrentMediaTime() + 0.2
                fade.fillMode = .backwards // hold the old (zero) opacity until it starts
            }
            shape.add(fade, forKey: "shadow")
            let chromeFrom = chrome.presentation()?.opacity ?? chrome.opacity
            if chromeFrom != chromeOpacity {
                let chromeFade = CABasicAnimation(keyPath: "opacity")
                chromeFade.fromValue = chromeFrom
                chromeFade.toValue = chromeOpacity
                chromeFade.duration = chromeOpacity == 0 ? 0.15 : 0.28
                chromeFade.timingFunction = chromeOpacity == 0 ? Anim.leave : Anim.arrive
                chrome.add(chromeFade, forKey: "opacity")
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in [shape, backdropMask, chromeMask, rim, aura] { l.path = newPath }
        pillMask.path = newPath
        pillMask.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
        shape.shadowPath = newPath
        aura.shadowPath = newPath
        sheen.locations = sheenLocations(size)
        chrome.opacity = chromeOpacity
        // A shadow is a blur pass; only pay for it while it shows.
        shape.shadowOpacity = expanded ? Theme.current.glowOpacity : 0
        sweepTrack.frame = CGRect(x: (bounds.width - size.width) / 2, y: size.height - Self.sweepHeight,
                                  width: size.width, height: Self.sweepHeight)
        CATransaction.commit()
    }

    // MARK: Light: aura, sweep, finish flash, nudge

    private func syncAura(mode: NotchMode) {
        // The collapsed pill stays calm; only a "needs you" card glows.
        let status = mode == .peek ? store.stickyEvent?.status : nil
        // Needs you: a quicker, brighter pulse. Working: a slow breath. Anything else: dark.
        let style: (period: Double, low: Float, high: Float)? = switch status {
        case .pendingApproval?, .awaitingInput?, .guestRequest?: (0.8, 0.35, 0.95)
        case .working?, .connecting?: (1.8, 0.12, 0.5)
        default: nil
        }
        let key = style.map { "\(status!)-\($0.period)" } ?? "off"
        guard key != auraKey else { return }
        auraKey = key
        aura.removeAnimation(forKey: "breathe")
        guard let style, let status else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        aura.shadowColor = status.color.cgColor
        CATransaction.commit()
        let breathe = CABasicAnimation(keyPath: "shadowOpacity")
        breathe.fromValue = style.low
        breathe.toValue = style.high
        breathe.duration = style.period
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        aura.add(breathe, forKey: "breathe")
    }

    private static let sweepWidth: CGFloat = 150
    private static let sweepHeight: CGFloat = 1.5

    /// A short light gliding once left to right along the bottom edge.
    private func runSweep(_ color: NSColor, delay: Double = 0) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sweep.colors = [color.withAlphaComponent(0), color.withAlphaComponent(0.95), color.withAlphaComponent(0)].map(\.cgColor)
        CATransaction.commit()
        let move = CABasicAnimation(keyPath: "position.x")
        move.fromValue = -Self.sweepWidth / 2
        move.toValue = sweepTrack.bounds.width + Self.sweepWidth / 2
        move.duration = 0.9
        move.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        move.beginTime = CACurrentMediaTime() + delay
        sweep.add(move, forKey: "sweepOnce")
    }

    /// A run finished: green (or red) light flares under the edge and runs along the bottom,
    /// with the checkmark drawing itself in the card and the shape's bouncier spring.
    private func celebrate(_ t: T3Thread) {
        let color = (t.status == .failed ? ThreadStatus.failed : ThreadStatus.completed).color
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        aura.shadowColor = color.cgColor
        CATransaction.commit()
        let flash = CAKeyframeAnimation(keyPath: "shadowOpacity")
        flash.values = [0, 0.95, 0.45, 0]
        flash.keyTimes = [0, 0.15, 0.5, 1]
        flash.duration = 1.8
        flash.beginTime = CACurrentMediaTime() + 0.1
        flash.fillMode = .backwards
        aura.add(flash, forKey: "flash")
        runSweep(color, delay: 0.3)
    }

    /// Something needs you: a small side-to-side wiggle once the card has opened, the way
    /// iOS shakes a wrong passcode, only gentler.
    private func nudge() {
        let wiggle = CAKeyframeAnimation(keyPath: "transform.translation.x")
        wiggle.values = [0, 7, -6, 4, -2, 0]
        wiggle.keyTimes = [0, 0.15, 0.35, 0.55, 0.78, 1]
        wiggle.duration = 0.5
        wiggle.beginTime = CACurrentMediaTime() + 0.35
        wiggle.isAdditive = true
        wiggle.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer?.add(wiggle, forKey: "nudge")
    }

    // MARK: Expanded list / cards, only while open

    private func syncContent(mode: NotchMode, size: CGSize, shapeFrom: CGPath?, damping: CGFloat) {
        let event = store.event
        let key: String = switch mode {
        case .expanded: "expanded"
        case .peek: event.map { "peek:\($0.id):\($0.status.needsYou)" } ?? ""
        default: ""
        }
        if key != contentKey {
            contentKey = key
            if let old = content {
                content = nil
                retire(old, size: size, damping: damping)
            }
            if !key.isEmpty {
                let view: NSView = switch mode {
                case .expanded: ExpandedView(model: model, store: store)
                default: event?.status.needsYou == true
                    ? NeedsYouView(model: model, store: store) : FinishedView(model: model, store: store)
                }
                view.wantsLayer = true
                view.layer?.mask = CAShapeLayer()
                addSubview(view)
                content = view
                // Drops in with the shape as it opens, a beat after it starts to grow. The list
                // only fades: its rows cascade in on their own.
                let list = mode == .expanded
                Anim.enter(view, delay: 0.06, drop: list ? 0 : 6, blurRadius: list ? 0 : 6)
                if mode == .peek, let event {
                    if event.status.needsYou { nudge() } else { celebrate(event) }
                }
            }
        }
        guard let content else { return }
        let frame = CGRect(x: (bounds.width - size.width) / 2, y: 0, width: size.width, height: size.height)
        let mask = content.layer?.mask as? CAShapeLayer
        if content.frame != frame || shapeFrom != nil {
            content.frame = frame
            let target = NotchShape.path(size: size, topRadius: model.topRadius, bottomRadius: model.bottomRadius)
            if let shapeFrom, let mask {
                // Clip the content with the *same* spring as the black shape, so it never shows
                // outside the notch while it grows. Shape paths live in our coordinates; the mask
                // is in the content view's, so shift by its origin.
                var shift = CGAffineTransform(translationX: -frame.minX, y: 0)
                let spring = Self.spring("path", damping: damping) // the shape's own spring
                spring.fromValue = shapeFrom.copy(using: &shift)
                spring.toValue = target
                mask.add(spring, forKey: "path")
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            mask?.frame = content.bounds
            mask?.path = target
            CATransaction.commit()
        }
        switch content {
        case let v as ExpandedView:
            v.damping = self.damping
            v.update()
        case let v as NeedsYouView: if let e = event { v.configure(e) }
        case let v as FinishedView: if let e = event { v.configure(e) }
        default: break
        }
    }

    /// Old content fades away, still clipped to the shape as it springs to its new size (it
    /// used to keep its old clip and show past the edge while the notch shrank).
    private func retire(_ old: NSView, size: CGSize, damping: CGFloat) {
        if let mask = old.layer?.mask as? CAShapeLayer {
            var shift = CGAffineTransform(translationX: -old.frame.minX, y: 0)
            let target = path(for: size).copy(using: &shift)
            let spring = Self.spring("path", damping: damping)
            spring.fromValue = mask.presentation()?.path ?? mask.path
            spring.toValue = target
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            mask.path = target
            CATransaction.commit()
            mask.add(spring, forKey: "path")
        }
        Anim.exit(old, duration: 0.1) { old.removeFromSuperview() }
    }

    /// Open (list or card): every store change updates it; collapsed only on visible changes.
    var isInteractive: Bool { content != nil }
}

// MARK: - Status pill

/// The collapsed notch: what's waiting on you as icons on the left, one line of words on the
/// right ("2 need you"), or a spinner and "5 working" when nothing waits. When both happen,
/// the work keeps the left (spinner and "6 working") and what's waiting moves right (its
/// icons, then "2 need you"); with `Settings.needsYouOnLeft`, what's waiting keeps the left
/// and the work moves right.
/// Beside a camera notch the two sides sit in the wings on either side of it.
///
/// It spans the whole canvas, so its parts can glide with the shape's edges on the same spring.
/// Numbers roll digit by digit, icons pop in and out one by one, and nothing that stays the
/// same moves.
@MainActor
final class StatusPill: NSView {
    private let model: NotchModel
    private let store: ThreadStore
    /// What's waiting, as icons: at the left edge, or leading "2 need you" on the right while
    /// the work keeps the left. One set for each place, like the spinners.
    private var iconViews: [NotchSummary.Kind: NSImageView] = [:]
    private var rightIconViews: [NotchSummary.Kind: NSImageView] = [:]
    /// The work's spinner: at the left edge, or leading "6 working" on the right beside what's
    /// waiting when that keeps the left. One for each place, so a split or join cross-fades
    /// between them instead of sliding across the camera.
    private let leftSpinner = Spinner()
    private let rightSpinner = Spinner()
    /// The words at the right edge: "5 working" or "2 need you" alone; beside the other side,
    /// whichever count sits on the right (so it keeps its place and rolls when the sides split
    /// or join).
    private let rightLabel = RollingLabel(align: .right)
    /// The left side's words while the sides are split: "2 need you" after the icons, or
    /// "6 working" after the spinner.
    private let leftLabel = RollingLabel(align: .left)
    /// Which side what's waiting takes while work sits beside it.
    private var needsYouOnLeft: Bool { Settings.needsYouOnLeft }
    private var kinds: [NotchSummary.Kind] = []
    private var shown = false
    /// Width of the notch shape the parts sit in (centered in the canvas).
    private var shapeWidth: CGFloat = 0
    private var damping: CGFloat = 0.78
    /// Just faded back in: place everything where it belongs without sliding it there.
    private var appearing = true
    private var spinnerStops: [ObjectIdentifier: DispatchWorkItem] = [:]
    /// The shape's left and right edges last time, so parts that appear or fade away travel
    /// with the edge they belong to instead of sitting still while the notch springs.
    private var edges: (left: CGFloat, right: CGFloat)?
    /// Parts that just started to show, for the next `place`: they ride in with their edge.
    private var appeared: Set<ObjectIdentifier> = []

    static let font = UI.rounded(13, .semibold)
    static let iconSlot: CGFloat = 16
    static let iconGap: CGFloat = 4
    /// Between a side's icons and its words.
    static let wordsGap: CGFloat = 5

    init(model: NotchModel, store: ThreadStore) {
        self.model = model
        self.store = store
        super.init(frame: .zero)
        wantsLayer = true
        let slot = CGRect(x: 0, y: 0, width: Self.iconSlot, height: Self.iconSlot) // pops from its middle
        for kind in NotchSummary.Kind.allCases {
            for right in [false, true] {
                let v = NSImageView()
                v.imageScaling = .scaleProportionallyDown
                v.image = Self.symbol(kind)
                v.wantsLayer = true
                v.frame = slot
                v.alphaValue = 0
                if right { rightIconViews[kind] = v } else { iconViews[kind] = v }
                addSubview(v)
            }
        }
        for v in [leftSpinner, rightSpinner] { v.frame = slot }
        for v in [leftSpinner, rightSpinner, leftLabel] as [NSView] { v.alphaValue = 0 }
        [leftSpinner, rightSpinner, leftLabel, rightLabel].forEach(addSubview)
        alphaValue = 0
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil } // clicks open the notch (root view)

    static func color(_ kind: NotchSummary.Kind) -> NSColor {
        switch kind {
        case .question: ThreadStatus.pendingApproval.color
        case .plan: ThreadStatus.planReady.color
        case .failed: ThreadStatus.failed.color
        case .done: ThreadStatus.completed.color
        }
    }

    private static func symbol(_ kind: NotchSummary.Kind) -> NSImage? {
        let name = switch kind {
        case .question: "questionmark.circle.fill"
        case .plan: "list.bullet.clipboard.fill"
        case .failed: "xmark.circle.fill"
        case .done: "checkmark.circle.fill"
        }
        // Two layers: the mark cut in black, the disc in the kind's color (one color fills both,
        // and the "?" or "✓" disappears into a plain dot).
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            .applying(.init(paletteColors: [.black, color(kind)]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }

    private static func wordsWidth(_ text: String) -> CGFloat {
        ceil(NSAttributedString(string: text, attributes: [.font: font]).size().width) + 4
    }

    private static func iconsWidth(_ s: NotchSummary) -> CGFloat {
        let n = CGFloat(max(1, s.waiting.count)) // the spinner takes one slot
        return n * iconSlot + (n - 1) * iconGap
    }

    /// Room each side needs, for sizing the notch before anything is drawn: the icons (or
    /// spinner) on the left and the words on the right, or, with work beside something waiting,
    /// spinner + "6 working" on one side and icons + "2 need you" on the other.
    static func widths(_ s: NotchSummary) -> (left: CGFloat, right: CGFloat) {
        guard let text = s.text else { return (0, 0) }
        let icons = iconsWidth(s), words = wordsWidth(text)
        guard let aside = s.workingAside else { return (icons, words) }
        let waiting = icons + wordsGap + words, work = iconSlot + wordsGap + wordsWidth(aside)
        return Settings.needsYouOnLeft ? (waiting, work) : (work, waiting)
    }

    func setVisible(_ visible: Bool) {
        guard let l = layer else { isHidden = !visible; return }
        if visible {
            guard isHidden || alphaValue < 1 else { return }
            isHidden = false
            appearing = true
            // In as the shape settles back around it, once the open list has cleared.
            Anim.fade(l, to: 1, duration: 0.24, delay: 0.12, key: "visible")
            Anim.blur(l, in: self, from: 5, to: 0, duration: 0.32, delay: 0.12)
            alphaValue = 1
        } else {
            guard !isHidden, alphaValue > 0 else { return }
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.alphaValue == 0 else { return }
                    self.isHidden = true
                }
            }
            Anim.fade(l, to: 0, duration: 0.1, key: "visible")
            Anim.blur(l, in: self, from: 0, to: 5, duration: 0.1)
            alphaValue = 0
            CATransaction.commit()
        }
    }

    func update(width: CGFloat, damping: CGFloat) {
        let s = store.summary
        guard let text = s.text else { return }
        shapeWidth = width
        self.damping = damping
        let animate = !appearing && shown && window != nil
        appearing = false
        shown = true
        kinds = s.waiting
        let split = s.workingAside != nil
        func words(_ t: String) -> NSAttributedString {
            NSAttributedString(string: t, attributes: [.font: Self.font, .foregroundColor: NSColor.white])
        }
        func show(_ v: NSView, _ on: Bool, scale: CGFloat, delay: Double = 0) {
            if on, v.alphaValue < 0.5 { appeared.insert(ObjectIdentifier(v)) }
            Anim.reveal(v, on, animated: animate, scale: scale, delay: delay)
        }
        let onLeft = needsYouOnLeft
        rightLabel.set(words(onLeft ? s.workingAside ?? text : text), animated: animate)
        // The left words keep their last text while they fade out.
        if let aside = s.workingAside {
            leftLabel.set(words(onLeft ? text : aside), animated: animate && leftLabel.alphaValue > 0.5)
        }
        show(leftLabel, split, scale: 0.9)
        // A new icon pops in a beat late, once the words beside it have slid over to make room.
        let iconsRight = split && !onLeft
        for (set, side) in [(iconViews, false), (rightIconViews, true)] {
            for (kind, v) in set {
                let on = kinds.contains(kind) && side == iconsRight
                show(v, on, scale: 0.4, delay: on ? 0.06 : 0)
            }
        }
        let working = s.working > 0
        let spinnerRight = split && onLeft
        for (spinner, on) in [(leftSpinner, working && !spinnerRight), (rightSpinner, working && spinnerRight)] {
            show(spinner, on, scale: 0.4)
            let id = ObjectIdentifier(spinner)
            spinnerStops[id]?.cancel()
            if on {
                spinner.setSpinning(true, color: Theme.current.working)
            } else {
                // Keep turning while it fades out, then rest.
                let stop = DispatchWorkItem { [weak spinner] in spinner?.setSpinning(false, color: Theme.current.working) }
                spinnerStops[id] = stop
                DispatchQueue.main.asyncAfter(deadline: .now() + (animate ? 0.35 : 0), execute: stop)
            }
        }
        place(animated: animate)
    }

    /// Where everything goes. The left edge holds the spinner or the icons, and that side's
    /// words while the sides are split; the right edge holds the words, led by the spinner or
    /// the icons while split.
    private func place(animated: Bool) {
        guard shown, shapeWidth > 0 else { return }
        let h = bounds.height
        let x0 = ((bounds.width - shapeWidth) / 2).rounded(), x1 = x0 + shapeWidth
        // How far each edge is moving: things appearing start that far back, so they ride in
        // with it.
        let shift = (left: (edges?.left ?? x0) - x0, right: (edges?.right ?? x1) - x1)
        edges = (x0, x1)
        let inset = model.sideInset(for: .activity)
        let iconY = ((h - Self.iconSlot) / 2).rounded()
        let lh = rightLabel.fittingHeight
        let labelY = ((h - lh) / 2).rounded()
        let move = { (v: NSView, f: CGRect, anchor: Anim.Anchor) in
            let from = animated && self.appeared.contains(ObjectIdentifier(v))
                ? f.offsetBy(dx: anchor == .leading ? shift.left : shift.right, dy: 0) : nil
            Anim.glide(v, to: f, from: from, anchor: anchor, damping: self.damping, animated: animated)
        }
        let slot = { (x: CGFloat) in CGRect(x: x, y: iconY, width: Self.iconSlot, height: Self.iconSlot) }
        move(leftSpinner, slot(x0 + inset), .leading)
        var x = x0 + inset
        for kind in NotchSummary.Kind.allCases {
            guard let v = iconViews[kind] else { continue }
            if kinds.contains(kind) {
                move(v, slot(x), .leading)
                x += Self.iconSlot + Self.iconGap
            } else {
                move(v, v.frame.offsetBy(dx: -shift.left, dy: 0), .leading) // fading: rides the edge
            }
        }
        let n = CGFloat(kinds.count)
        let iw = n * Self.iconSlot + max(0, n - 1) * Self.iconGap
        if leftLabel.alphaValue > 0 {
            // After the icons when what's waiting keeps the left, otherwise after the spinner.
            let lead = needsYouOnLeft ? iw : Self.iconSlot
            move(leftLabel, CGRect(x: x0 + inset + lead + Self.wordsGap, y: labelY, width: leftLabel.fittingWidth, height: lh), .leading)
        } else {
            move(leftLabel, leftLabel.frame.offsetBy(dx: -shift.left, dy: 0), .leading) // fading: rides the edge
        }
        let tw = rightLabel.fittingWidth
        let right = CGRect(x: x1 - inset - tw, y: labelY, width: tw, height: lh)
        move(rightLabel, right, .trailing)
        move(rightSpinner, slot(right.minX - Self.wordsGap - Self.iconSlot), .trailing)
        var rx = right.minX - Self.wordsGap - iw
        for kind in NotchSummary.Kind.allCases {
            guard let v = rightIconViews[kind] else { continue }
            if kinds.contains(kind) {
                move(v, slot(rx), .trailing)
                rx += Self.iconSlot + Self.iconGap
            } else {
                move(v, v.frame.offsetBy(dx: -shift.right, dy: 0), .trailing) // fading: rides the edge
            }
        }
        appeared = []
    }

    override func layout() {
        super.layout()
        place(animated: false)
    }
}

/// A ring with a gap, turning: work in progress. Runs in the window server.
@MainActor
final class Spinner: NSView {
    private let track = CAShapeLayer()
    private let arc = CAShapeLayer()
    private var spinning = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for l in [track, arc] {
            l.fillColor = nil
            l.lineWidth = 2
            l.lineCap = .round
            layer?.addSublayer(l)
        }
        arc.strokeEnd = 0.3
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let ring = CGPath(ellipseIn: bounds.insetBy(dx: 2, dy: 2), transform: nil)
        for l in [track, arc] {
            l.frame = bounds
            l.path = ring
        }
        CATransaction.commit()
    }

    func setSpinning(_ on: Bool, color: NSColor) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.strokeColor = color.withAlphaComponent(0.25).cgColor
        arc.strokeColor = color.cgColor
        CATransaction.commit()
        guard on != spinning || (on && arc.animation(forKey: "spin") == nil) else { return }
        spinning = on
        guard on else { arc.removeAnimation(forKey: "spin"); return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = 2 * Double.pi
        spin.duration = 0.9
        spin.repeatCount = .infinity
        arc.add(spin, forKey: "spin")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // CA drops animations when a layer leaves its window: start over on the way back.
        guard spinning, window != nil, let color = arc.strokeColor.flatMap(NSColor.init(cgColor:)) else { return }
        spinning = false
        setSpinning(true, color: color)
    }
}

// MARK: - Indicator

/// Status glyph: the provider's pixel logo sweeping (working / connecting, when the provider is
/// given; three dots otherwise), breathing dot (needs you), an icon for the rest, nothing for
/// idle. All Core Animation.
@MainActor
final class StatusIndicator: NSView {
    private let dots = LayerDots(dots: 3)
    private let pulse = LayerDots(dots: 1)
    private let icon = NSImageView()
    private let pixel = PixelGlyph()
    private var shown: (ThreadStatus, Bool, String??)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        [dots, pulse, icon, pixel].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        [dots, pulse, icon].forEach { $0.frame = bounds }
        let side = min(bounds.width, bounds.height)
        pixel.frame = CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
    }

    /// `provider`: whose pixel logo sweeps while busy (`.some(nil)`: unknown provider, a plain
    /// block); leave it out for the three dots.
    func show(_ status: ThreadStatus, small: Bool, provider: String?? = nil) {
        if let s = shown, s.0 == status, s.1 == small, s.2 == provider { return }
        shown = (status, small, provider)
        let color = status.color
        let busy = status == .working || status == .connecting
        // With a provider, working sweeps its pixel logo and waiting drifts a soft band over it.
        let logo = (busy || status == .waiting) && provider != nil
        pixel.isHidden = !logo
        if logo, let provider {
            pixel.configure(provider: provider, motion: status == .waiting ? .wave : .sweep(slow: status == .connecting))
        }
        dots.isHidden = !busy || provider != nil
        pulse.isHidden = !(status.needsYou || status == .guestRequest)
        let symbol: String? = switch status {
        case .waiting: "hourglass"
        case .failed: "xmark.circle.fill"
        case .planReady: "list.bullet.clipboard.fill"
        case .completed: "checkmark.circle.fill"
        default: nil
        }
        icon.isHidden = symbol == nil || logo
        if let symbol {
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: status.label)?
                .withSymbolConfiguration(.init(pointSize: small ? 11 : 12, weight: .semibold))
            icon.contentTintColor = color
        }
        dots.configure(color: status == .connecting ? color.withAlphaComponent(0.55) : color,
                       size: small ? 3.5 : 4.5, style: .wave)
        pulse.configure(color: color, size: 8, style: .pulse)
    }
}

final class LayerDots: NSView {
    enum Style { case wave, pulse }

    private let dots: [CALayer]
    private let halo = CALayer()
    private var config: (NSColor, CGFloat, Style)?

    init(dots count: Int) {
        dots = (0..<count).map { _ in CALayer() }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(halo)
        dots.forEach { layer?.addSublayer($0) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(color: NSColor, size: CGFloat, style: Style) {
        if let c = config, c.0 == color, c.1 == size, c.2 == style { return } // SwiftUI calls this often
        config = (color, size, style)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for dot in dots {
            dot.backgroundColor = color.cgColor
            dot.cornerRadius = size / 2
            dot.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        }
        halo.backgroundColor = color.withAlphaComponent(0.35).cgColor
        halo.cornerRadius = 8
        halo.bounds = CGRect(x: 0, y: 0, width: 16, height: 16)
        halo.isHidden = style != .pulse
        CATransaction.commit()
        needsLayout = true
        restartAnimations()
    }

    override func layout() {
        super.layout()
        guard let (_, size, style) = config else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch style {
        case .wave:
            let gap = size * 0.6
            let total = size * 3 + gap * 2
            for (i, dot) in dots.enumerated() {
                dot.position = CGPoint(x: (bounds.width - total) / 2 + size / 2 + CGFloat(i) * (size + gap),
                                       y: bounds.midY - size * 0.4)
            }
        case .pulse:
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            halo.position = center
            dots.forEach { $0.position = center }
        }
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        restartAnimations() // CA drops animations when a layer leaves its window
    }

    private func restartAnimations() {
        guard window != nil, let (_, size, style) = config else { return }
        switch style {
        case .wave:
            let period = 1.1
            for (i, dot) in dots.enumerated() {
                // Up-swing then rest, each dot a beat behind the previous one.
                let lift = CAKeyframeAnimation(keyPath: "transform.translation.y")
                lift.values = [0, size * 0.8, 0, 0]
                lift.keyTimes = [0, 0.25, 0.5, 1]
                let fade = CAKeyframeAnimation(keyPath: "opacity")
                fade.values = [0.4, 1, 0.4, 0.4]
                fade.keyTimes = lift.keyTimes
                let group = CAAnimationGroup()
                group.animations = [lift, fade]
                group.duration = period
                group.repeatCount = .infinity
                group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                group.beginTime = CACurrentMediaTime() + Double(i) * period * 0.15
                group.fillMode = .backwards
                dot.opacity = 0.4
                dot.add(group, forKey: "wave")
            }
        case .pulse:
            let breathe = CABasicAnimation(keyPath: "transform.scale")
            breathe.fromValue = 0.5
            breathe.toValue = 1
            breathe.duration = 0.8
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            halo.add(breathe, forKey: "pulse")
        }
    }
}
