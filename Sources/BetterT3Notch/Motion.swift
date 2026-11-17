import AppKit
import CoreImage

/// One family of springs and curves for the whole notch. Everything here is a CAAnimation, so
/// the window server runs it and the app does no work per frame. Every helper starts from what's
/// on screen right now (the presentation layer), so a change mid-flight carries on smoothly
/// instead of jumping.
@MainActor
enum Anim {
    /// A spring by response (seconds per oscillation) and damping fraction, like SwiftUI's.
    nonisolated static func spring(_ keyPath: String, response: CGFloat = 0.42, damping: CGFloat = 0.78) -> CASpringAnimation {
        let a = CASpringAnimation(keyPath: keyPath)
        let omega = 2 * .pi / response
        a.mass = 1
        a.stiffness = omega * omega
        a.damping = 2 * damping * omega
        a.duration = a.settlingDuration
        return a
    }

    /// Quick start, long gentle landing: things arriving.
    static let arrive = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
    /// Gentle start, quick finish: things leaving.
    static let leave = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.9, 0.6)
    /// Symmetric, for state changes in place (hover, color).
    static let swap = CAMediaTimingFunction(controlPoints: 0.45, 0, 0.25, 1)

    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    static func scaled(_ bounds: CGRect, _ s: CGFloat) -> CATransform3D {
        // View layers are anchored at their corner: scale around the middle instead.
        var t = CATransform3DMakeTranslation(bounds.midX, bounds.midY, 0)
        t = CATransform3DScale(t, s, s, 1)
        return CATransform3DTranslate(t, -bounds.midX, -bounds.midY, 0)
    }

    /// Fade a layer's opacity from where it is now to `to`, and keep it there.
    static func fade(_ l: CALayer, to: Float, duration: Double, curve: CAMediaTimingFunction? = nil,
                     delay: Double = 0, key: String = "fade") {
        let from = l.presentation()?.opacity ?? l.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        l.opacity = to
        CATransaction.commit()
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = from
        a.toValue = to
        a.duration = duration
        a.timingFunction = curve ?? (to > from ? arrive : leave)
        if delay > 0 {
            a.beginTime = CACurrentMediaTime() + delay
            a.fillMode = .backwards
        }
        l.add(a, forKey: key)
    }

    /// Motion blur: things come into focus as they arrive and soften as they go, the way
    /// iOS does it, so a quick move reads as motion rather than a jump. The filter only lives
    /// on the layer while it animates (a blur is a render pass; at rest it costs nothing).
    /// `view`: the view that owns `l` (or hosts it), which has to opt in to filters.
    static func blur(_ l: CALayer, in view: NSView?, from: CGFloat, to: CGFloat, duration: Double,
                     delay: Double = 0, curve: CAMediaTimingFunction? = nil) {
        guard !reduced, from != to, let filter = CIFilter(name: "CIGaussianBlur") else { return }
        view?.layerUsesCoreImageFilters = true
        filter.name = "blur"
        filter.setValue(to, forKey: kCIInputRadiusKey)
        let token = NSObject()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        l.filters = [filter]
        l.setValue(token, forKey: "blurToken")
        CATransaction.commit()
        CATransaction.begin()
        // Clear it once done (in focus, or blurred out and invisible), unless a newer blur took
        // over meanwhile.
        CATransaction.setCompletionBlock {
            guard l.value(forKey: "blurToken") as? NSObject === token else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            l.filters = nil
            CATransaction.commit()
        }
        let a = CABasicAnimation(keyPath: "filters.blur.inputRadius")
        a.fromValue = from
        a.toValue = to
        a.duration = duration
        a.timingFunction = curve ?? (to < from ? arrive : leave)
        if delay > 0 {
            a.beginTime = CACurrentMediaTime() + delay
            a.fillMode = .backwards
        }
        l.add(a, forKey: "blur")
        CATransaction.commit()
    }

    enum Anchor { case leading, trailing }

    /// Move a view to `frame`, sliding from where it is on screen now on a spring. `anchor`:
    /// which edge travels (a right-aligned label keeps its right edge on the path, whatever its
    /// width does). Pass the notch shape's damping to move in step with it.
    /// `from`: start there instead of where it is on screen (something just appearing, placed
    /// where its neighbours are coming from).
    static func glide(_ v: NSView, to frame: CGRect, from start: CGRect? = nil, anchor: Anchor = .leading,
                      response: CGFloat = 0.42, damping: CGFloat = 0.78, animated: Bool = true) {
        if let start {
            v.frame = start
            v.layer?.removeAnimation(forKey: "glide")
        }
        let old = v.frame
        guard old != frame else { return }
        // Still showing counts too: something fading out keeps moving while it fades.
        let showing = v.alphaValue > 0 || (v.layer?.presentation()?.opacity ?? 0) > 0.01
        guard animated, let l = v.layer, v.window != nil, !v.isHidden, showing, old.width > 0 || old.height > 0 else {
            v.frame = frame
            v.layer?.removeAnimation(forKey: "glide")
            return
        }
        let p0 = l.position
        let inFlight = start != nil ? .zero
            : l.presentation().map { CGPoint(x: $0.position.x - p0.x, y: $0.position.y - p0.y) } ?? .zero
        v.frame = frame
        let p1 = l.position
        let dx = (anchor == .leading ? old.minX - frame.minX : old.maxX - frame.maxX) + inFlight.x
        let dy = p0.y - p1.y + inFlight.y // layer space: a flipped parent flips y
        guard abs(dx) > 0.25 || abs(dy) > 0.25 else { l.removeAnimation(forKey: "glide"); return }
        let s = spring("position", response: response, damping: damping)
        s.fromValue = NSValue(point: CGPoint(x: dx, y: dy))
        s.toValue = NSValue(point: .zero)
        s.isAdditive = true
        l.add(s, forKey: "glide")
    }

    /// Show or hide a view in place: it pops up from `scale` with a little bounce and fades in,
    /// or shrinks and fades away. State lives in `alphaValue` (0 or 1), so it can be reversed
    /// halfway through.
    /// `fresh`: it was just moved, so start from nothing rather than from what's on screen.
    static func reveal(_ v: NSView, _ on: Bool, animated: Bool, scale: CGFloat = 0.5, delay: Double = 0, fresh: Bool = false) {
        let target: CGFloat = on ? 1 : 0
        guard let l = v.layer else { v.alphaValue = target; return }
        guard fresh || (v.alphaValue > 0.5) != on else { return }
        let fromOpacity = fresh ? 0 : l.presentation()?.opacity ?? Float(v.alphaValue)
        let fromTransform = fresh ? CATransform3DIdentity : l.presentation()?.transform ?? CATransform3DIdentity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        v.alphaValue = target
        CATransaction.commit()
        guard animated, v.window != nil else {
            for key in ["reveal", "reveal.scale", "blur"] { l.removeAnimation(forKey: key) }
            l.filters = nil
            return
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = fromOpacity
        fade.toValue = Float(target)
        fade.duration = on ? 0.22 : 0.14
        fade.timingFunction = on ? arrive : leave
        if delay > 0 {
            fade.beginTime = CACurrentMediaTime() + delay
            fade.fillMode = .backwards
        }
        l.add(fade, forKey: "reveal")
        blur(l, in: v, from: on ? 4 : 0, to: on ? 0 : 4, duration: on ? 0.3 : 0.14, delay: delay)
        // (Not placed yet: there's no middle to scale around, so it only fades.)
        guard scale != 1, !reduced, !l.bounds.isEmpty else { l.removeAnimation(forKey: "reveal.scale"); return }
        let small = scaled(l.bounds, scale)
        let s = on ? spring("transform", response: 0.4, damping: 0.62) : spring("transform", response: 0.3, damping: 1)
        s.fromValue = NSValue(caTransform3D: on && fromOpacity < 0.05 ? small : fromTransform)
        s.toValue = NSValue(caTransform3D: on ? CATransform3DIdentity : small)
        if on, delay > 0 {
            s.beginTime = fade.beginTime
            s.fillMode = .backwards
        }
        if !on { // stays small while invisible; the next reveal takes over from here
            s.fillMode = .forwards
            s.isRemovedOnCompletion = false
        }
        l.add(s, forKey: "reveal.scale")
    }

    /// Arriving content: comes into focus as it fades in and drops a few points into place.
    static func enter(_ v: NSView, delay: Double = 0, drop: CGFloat = 8, blurRadius: CGFloat = 4) {
        guard let l = v.layer, v.window != nil else { return }
        let begin = CACurrentMediaTime() + delay
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = l.opacity
        fade.duration = 0.3
        fade.timingFunction = arrive
        fade.beginTime = begin
        fade.fillMode = .backwards
        l.add(fade, forKey: "enter")
        blur(l, in: v, from: blurRadius, to: 0, duration: 0.34, delay: delay)
        guard !reduced, drop != 0 else { return }
        let move = spring("transform.translation.y", response: 0.45, damping: 0.86)
        move.fromValue = -drop
        move.toValue = 0
        move.isAdditive = true
        move.beginTime = begin
        move.fillMode = .backwards
        l.add(move, forKey: "enter.move")
    }

    /// Leaving content: fades and shrinks a touch toward its middle, then `done` (remove it).
    static func exit(_ v: NSView, duration: Double = 0.16, done: @escaping @MainActor () -> Void) {
        guard let l = v.layer, v.window != nil else { done(); return }
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { done() } }
        fade(l, to: 0, duration: duration, curve: leave, key: "exit")
        blur(l, in: v, from: 0, to: 5, duration: duration, curve: leave)
        CATransaction.setDisableActions(true)
        v.alphaValue = 0 // keep AppKit's idea of it in line, so it never pops back mid-fade
        if !reduced {
            let shrink = CABasicAnimation(keyPath: "transform")
            shrink.fromValue = NSValue(caTransform3D: l.presentation()?.transform ?? CATransform3DIdentity)
            shrink.toValue = NSValue(caTransform3D: scaled(l.bounds, 0.97))
            shrink.duration = duration
            shrink.timingFunction = leave
            shrink.fillMode = .forwards
            shrink.isRemovedOnCompletion = false
            l.add(shrink, forKey: "exit.scale")
        }
        CATransaction.commit()
    }

    /// A view appearing in an already open layout (a reply button on hover, live output):
    /// a quick fade, so it doesn't blink in.
    static func fadeIn(_ v: NSView, duration: Double = 0.18) {
        guard let l = v.layer, v.window != nil else { return }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 0
        a.toValue = l.opacity
        a.duration = duration
        a.timingFunction = arrive
        l.add(a, forKey: "fadeIn")
    }
}

// MARK: - Rolling text

/// Text whose numbers roll. Only what changed moves: 5 → 6 rolls the one digit while
/// " working" stays still; 9 → 10 rolls the 9 into a 0 while a 1 rolls in beside it, and the
/// words slide over to make room. Words that change ("needs you" → "need you") cross-fade with a
/// small lift. Each piece is a cached bitmap in its own layer, animated by Core Animation.
@MainActor
final class RollingLabel: NSView {
    enum Align { case left, right }

    /// A run of text. `number`: its digits roll. `style`: anything about its look that the
    /// string doesn't show (an icon's color), so a change cross-fades.
    struct Segment {
        var id: String
        var text: NSAttributedString
        var number = false
        var style = ""
    }

    private final class Piece {
        let layer = CALayer()
        var look: String
        var x: CGFloat
        var number: String?
        init(look: String, x: CGFloat, number: String?) { self.look = look; self.x = x; self.number = number }
    }

    private struct Spec {
        let key: String
        let text: NSAttributedString
        let look: String
        let x: CGFloat
        let width: CGFloat
        let number: String?
    }

    let align: Align
    private let strip = CALayer()
    private var pieces: [String: Piece] = [:]
    private var values: [String: Int] = [:]
    private var lineHeight: CGFloat = 0
    private var textWidth: CGFloat = 0
    private var signature = ""
    private var renderedScale: CGFloat = 0
    /// The text as plain words (what VoiceOver reads).
    private(set) var string = ""

    /// Text inset like an NSTextField's, so it lines up with plain labels.
    private static let inset: CGFloat = 2
    /// Room above and below the line in each piece's image, so tall or low glyphs aren't cut.
    /// Sideways each piece is clipped to its own advance (see `draw`).
    private static let pad: CGFloat = 2

    init(align: Align = .left) {
        self.align = align
        super.init(frame: .zero)
        wantsLayer = true
        layerUsesCoreImageFilters = true // motion blur on the rolling pieces
        strip.anchorPoint = .zero
        layer?.addSublayer(strip)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    // Display only: clicks go to the row or footer under it (they take the first click in the
    // panel, which never activates; a plain view here would swallow it).
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // The text is drawn into layers, so VoiceOver needs it spelled out, like a plain label
    // (and not once it has faded away).
    override func isAccessibilityElement() -> Bool { !string.isEmpty && alphaValue > 0 }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityValue() -> Any? { string.replacingOccurrences(of: "\u{FFFC}", with: "") }

    /// Width the text needs (like `UI.width` for a label).
    var fittingWidth: CGFloat { textWidth == 0 ? 0 : ceil(textWidth) + 2 * Self.inset }
    var fittingHeight: CGFloat { ceil(lineHeight) }
    override var intrinsicContentSize: NSSize { NSSize(width: fittingWidth, height: fittingHeight) }

    /// Plain or attributed text, split on its own: every run of digits is a number that rolls.
    func set(_ text: NSAttributedString, animated: Bool = true) {
        set(Self.segments(text), animated: animated)
    }

    static func segments(_ text: NSAttributedString) -> [Segment] {
        let s = text.string as NSString
        var out: [Segment] = []
        var start = 0, numbers = 0, words = 0
        func isDigit(_ i: Int) -> Bool { let c = s.character(at: i); return c >= 48 && c <= 57 }
        while start < s.length {
            let digits = isDigit(start)
            var end = start + 1
            while end < s.length, isDigit(end) == digits { end += 1 }
            let run = text.attributedSubstring(from: NSRange(location: start, length: end - start))
            if digits { out.append(Segment(id: "n\(numbers)", text: run, number: true)); numbers += 1 }
            else { out.append(Segment(id: "t\(words)", text: run)); words += 1 }
            start = end
        }
        return out
    }

    func set(_ segments: [Segment], animated: Bool = true) {
        // Called on every store update while the list is open: bail out before measuring
        // anything when nothing that shows has changed.
        let signature = segments.map { "\($0.id)\($0.number)=\(Self.look($0.text, $0.style))" }
            .joined(separator: "\u{1}") + "@\(backingScale)"
        guard signature != self.signature else { return }
        self.signature = signature
        lastSegments = segments
        let full = NSMutableAttributedString()
        segments.forEach { full.append($0.text) }
        string = full.string

        // Where every piece sits in the whole line (measured together, so spacing matches a label).
        var specs: [Spec] = []
        var offset = 0
        var prefixWidths: [Int: CGFloat] = [0: 0]
        func prefix(_ n: Int) -> CGFloat {
            if let w = prefixWidths[n] { return w }
            let w = full.attributedSubstring(from: NSRange(location: 0, length: n)).size().width
            prefixWidths[n] = w
            return w
        }
        var newValues: [String: Int] = [:]
        for seg in segments {
            let length = seg.text.length
            if seg.number {
                newValues[seg.id] = Int(seg.text.string)
                for i in 0..<length {
                    let ch = seg.text.attributedSubstring(from: NSRange(location: i, length: 1))
                    let x = prefix(offset + i)
                    specs.append(Spec(key: "\(seg.id)#\(length - 1 - i)", text: ch, look: Self.look(ch, seg.style),
                                      x: x, width: prefix(offset + i + 1) - x, number: seg.id))
                }
            } else if length > 0 {
                let x = prefix(offset)
                specs.append(Spec(key: seg.id, text: seg.text, look: Self.look(seg.text, seg.style),
                                  x: x, width: prefix(offset + length) - x, number: nil))
            }
            offset += length
        }
        let total = prefix(full.length)

        let height = full.length > 0 ? full.size().height : lineHeight
        let animate = animated && window != nil && !pieces.isEmpty && height == lineHeight && renderedScale == backingScale
        lineHeight = height
        textWidth = total
        renderedScale = backingScale

        // Which way each number turned: up rolls in from below, down from above.
        var turn: [String: CGFloat] = [:]
        for (id, value) in newValues { if let old = values[id] { turn[id] = value >= old ? 1 : -1 } }
        let overall = turn.values.first ?? 1
        values = newValues

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let wanted = Set(specs.map(\.key))
        for (key, piece) in pieces where !wanted.contains(key) {
            leave(piece, direction: piece.number.flatMap { turn[$0] } ?? overall, animated: animate)
            pieces[key] = nil
        }
        for spec in specs {
            let x = anchored(spec.x)
            let direction = spec.number.flatMap { turn[$0] } ?? overall
            if let piece = pieces[spec.key], piece.look == spec.look {
                if piece.x != x { slide(piece, to: x, animated: animate) }
                continue
            }
            if let old = pieces[spec.key] { leave(old, direction: direction, animated: animate) }
            let piece = Piece(look: spec.look, x: x, number: spec.number)
            draw(spec, of: full, into: piece)
            strip.addSublayer(piece.layer)
            pieces[spec.key] = piece
            if animate { arrive(piece, direction: direction, digit: spec.number != nil) }
        }
        CATransaction.commit()
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    /// Pieces are placed from the text's start (left) or end (right), so a right-aligned
    /// label's words stay put when its number grows a digit.
    private func anchored(_ x: CGFloat) -> CGFloat { align == .left ? x : x - textWidth }

    private var backingScale: CGFloat { window?.backingScaleFactor ?? 2 }

    private static func look(_ text: NSAttributedString, _ style: String) -> String {
        guard text.length > 0 else { return style }
        let attrs = text.attributes(at: 0, effectiveRange: nil)
        let color = (attrs[.foregroundColor] as? NSColor).map { "\($0)" } ?? ""
        let font = (attrs[.font] as? NSFont).map { "\($0.fontName)\($0.pointSize)" } ?? ""
        return text.string + "|" + style + "|" + color + "|" + font
    }

    /// A piece is its slice of the whole line, drawn in place, so every piece sits on the line's
    /// own baseline (an icon in the line makes it taller than a piece of plain text would be).
    /// It's clipped to its own advance, so a neighbour's ink never shows twice; the rounded
    /// digits and words used here stay inside their advances.
    private func draw(_ spec: Spec, of line: NSAttributedString, into piece: Piece) {
        let scale = backingScale
        let size = CGSize(width: ceil(spec.width) + Self.pad * 2, height: ceil(lineHeight) + Self.pad * 2)
        let image = NSImage(size: size, flipped: true) { _ in
            NSBezierPath(rect: CGRect(x: Self.pad, y: 0, width: spec.width, height: size.height)).addClip()
            line.draw(at: CGPoint(x: Self.pad - spec.x, y: Self.pad))
            return true
        }
        let l = piece.layer
        l.contents = image.layerContents(forContentsScale: scale)
        l.contentsScale = scale
        l.contentsGravity = .topLeft
        l.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        l.bounds = CGRect(origin: .zero, size: size)
        l.position = CGPoint(x: piece.x - Self.pad + size.width / 2, y: -Self.pad + size.height / 2)
    }

    private func slide(_ piece: Piece, to x: CGFloat, animated: Bool) {
        let l = piece.layer
        let from = (l.presentation() ?? l).position.x
        let dx = x - piece.x
        piece.x = x
        l.position.x += dx
        guard animated else { return }
        let s = Anim.spring("position.x", response: 0.34, damping: 0.9)
        s.fromValue = from
        s.toValue = l.position.x
        l.add(s, forKey: "slide")
    }

    /// How far a digit travels: most of a line, so it reads as rolling, not blinking.
    private var travel: CGFloat { Anim.reduced ? 0 : lineHeight * 0.7 }

    private func arrive(_ piece: Piece, direction: CGFloat, digit: Bool) {
        let l = piece.layer
        let distance = (digit ? travel : travel * 0.45) * direction
        // Digits roll past each other; new words wait a beat for the old ones to clear, so
        // two phrases never sit on top of each other.
        let begin = CACurrentMediaTime() + (digit ? 0 : 0.07)
        // A touch of bounce as it lands, like a wheel clicking into place.
        let move = Anim.spring("transform.translation.y", response: 0.5, damping: 0.72)
        move.fromValue = distance
        move.toValue = 0
        move.beginTime = begin
        move.fillMode = .backwards
        l.add(move, forKey: "roll")
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = digit ? 0.24 : 0.2
        fade.timingFunction = Anim.arrive
        fade.beginTime = begin
        fade.fillMode = .backwards
        l.add(fade, forKey: "fade")
        Anim.blur(l, in: self, from: digit ? 3 : 2.5, to: 0, duration: 0.3, delay: begin - CACurrentMediaTime())
        if digit, !Anim.reduced { // a hint of depth as it comes up the wheel
            let grow = Anim.spring("transform.scale.y", response: 0.5, damping: 0.72)
            grow.fromValue = 0.65
            grow.toValue = 1
            l.add(grow, forKey: "grow")
        }
    }

    private func leave(_ piece: Piece, direction: CGFloat, animated: Bool) {
        let l = piece.layer
        guard animated else { l.removeFromSuperlayer(); return }
        let p = l.presentation()
        let y = (p?.value(forKeyPath: "transform.translation.y") as? CGFloat) ?? 0
        let opacity = p?.opacity ?? 1
        l.removeAllAnimations()
        l.opacity = 0
        CATransaction.begin()
        CATransaction.setCompletionBlock { l.removeFromSuperlayer() }
        let distance = (piece.number != nil ? travel : travel * 0.45) * -direction
        let move = CABasicAnimation(keyPath: "transform.translation.y")
        move.fromValue = y
        move.toValue = distance
        move.duration = 0.3
        move.timingFunction = Anim.arrive // it's already moving: no slow start
        move.fillMode = .forwards
        move.isRemovedOnCompletion = false
        l.add(move, forKey: "roll")
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = opacity
        fade.toValue = 0
        fade.duration = piece.number != nil ? 0.18 : 0.09
        fade.timingFunction = Anim.leave
        l.add(fade, forKey: "fade")
        Anim.blur(l, in: self, from: 0, to: 3, duration: 0.18)
        if piece.number != nil, !Anim.reduced {
            let shrink = CABasicAnimation(keyPath: "transform.scale.y")
            shrink.fromValue = 1
            shrink.toValue = 0.65
            shrink.duration = 0.3
            shrink.timingFunction = Anim.arrive
            shrink.fillMode = .forwards
            shrink.isRemovedOnCompletion = false
            l.add(shrink, forKey: "grow")
        }
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        strip.position = CGPoint(x: align == .left ? Self.inset : bounds.width - Self.inset,
                                 y: ((bounds.height - lineHeight) / 2).rounded())
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard renderedScale != backingScale, !pieces.isEmpty else { return }
        // Redraw everything sharp for the new screen.
        pieces.values.forEach { $0.layer.removeFromSuperlayer() }
        pieces = [:]
        signature = ""
        set(lastSegments, animated: false)
    }

    private var lastSegments: [Segment] = []
}
