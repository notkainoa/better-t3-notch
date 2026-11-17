import AppKit
import Carbon.HIToolbox

/// The global "open the notch" shortcut: a key plus modifiers, saved in UserDefaults.
struct Shortcut: Equatable {
    var keyCode: UInt16
    var modifiers: NSEvent.ModifierFlags

    static let standard = Shortcut(keyCode: UInt16(kVK_Space), modifiers: [.command, .shift])

    private static let key = "openShortcut"

    static var saved: Shortcut {
        get {
            guard let dict = UserDefaults.standard.dictionary(forKey: key),
                  let code = dict["keyCode"] as? Int, let mods = dict["modifiers"] as? UInt
            else { return .standard }
            return Shortcut(keyCode: UInt16(code), modifiers: NSEvent.ModifierFlags(rawValue: mods).intersection(.relevant))
        }
        set {
            if newValue == .standard {
                UserDefaults.standard.removeObject(forKey: key)
            } else {
                UserDefaults.standard.set(["keyCode": Int(newValue.keyCode), "modifiers": newValue.modifiers.rawValue], forKey: key)
            }
        }
    }

    var carbonModifiers: UInt32 {
        var out = 0
        if modifiers.contains(.command) { out |= cmdKey }
        if modifiers.contains(.shift) { out |= shiftKey }
        if modifiers.contains(.option) { out |= optionKey }
        if modifiers.contains(.control) { out |= controlKey }
        return UInt32(out)
    }

    /// One label per key, in macOS's order (⌃⌥⇧⌘ then the key), for drawing as keycaps.
    var keyLabels: [String] { Self.modifierLabels(modifiers) + [Self.name(of: keyCode)] }

    var displayString: String { keyLabels.joined() }

    static func modifierLabels(_ mods: NSEvent.ModifierFlags) -> [String] {
        var out: [String] = []
        if mods.contains(.control) { out.append("⌃") }
        if mods.contains(.option) { out.append("⌥") }
        if mods.contains(.shift) { out.append("⇧") }
        if mods.contains(.command) { out.append("⌘") }
        return out
    }

    /// Function keys work alone; anything else needs ⌘, ⌥ or ⌃ (⇧ alone would eat typing).
    var isValid: Bool {
        Self.functionKeys.contains(Int(keyCode)) || !modifiers.intersection([.command, .option, .control]).isEmpty
    }

    /// Already one of macOS's own shortcuts (Spotlight, input sources, screenshots, Mission
    /// Control…), as set in System Settings → Keyboard Shortcuts. Other apps' shortcuts can't be
    /// seen: Carbon lets two apps register the same keys and gives it to one of them.
    var takenByMacOS: Bool {
        var ref: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&ref) == noErr, let list = ref?.takeRetainedValue() as? [[String: Any]] else { return false }
        let mine = Int(carbonModifiers)
        let mask = cmdKey | shiftKey | optionKey | controlKey
        return list.contains { hotKey in
            (hotKey[kHISymbolicHotKeyEnabled as String] as? Bool) == true
                && (hotKey[kHISymbolicHotKeyCode as String] as? Int) == Int(keyCode)
                && ((hotKey[kHISymbolicHotKeyModifiers as String] as? Int) ?? -1) & mask == mine
        }
    }

    private static let functionKeys: Set<Int> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    private static let special: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_ANSI_KeypadEnter: "⌤",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18",
        kVK_F19: "F19", kVK_F20: "F20",
    ]

    /// What the key prints on the current keyboard layout, unshifted (so ⇧1 reads "1", not "!").
    static func name(of keyCode: UInt16) -> String {
        if let s = special[Int(keyCode)] { return s }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return "#\(keyCode)" }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "#\(keyCode)" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}

extension NSEvent.ModifierFlags {
    static let relevant: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
}

// MARK: - Recorder

/// Click it, press a combo, done. Draws the shortcut as little keycaps; while recording it glows
/// in the accent color and shows the modifiers you're holding as you press them.
@MainActor
final class ShortcutRecorder: NSView {
    /// Return false to reject (registering failed); the recorder shakes and keeps the old one.
    var onChange: ((Shortcut) -> Bool)?
    /// Recording started (true) or ended (false): the live hotkey steps aside meanwhile.
    var onRecording: ((Bool) -> Void)?

    var shortcut: Shortcut = .standard {
        didSet { if !isRecording && oldValue != shortcut { showCaps(shortcut.keyLabels, animated: false) } }
    }

    private(set) var isRecording = false {
        didSet { if oldValue != isRecording { onRecording?(isRecording) } }
    }

    private let content = CALayer() // everything, centered, so presses and shakes scale from the middle
    private let pill = CALayer()
    private let glow = CALayer()
    private var caps: [KeyCapLayer] = []
    private let message = CATextLayer()
    private var monitor: Any?
    private var heldModifiers: NSEvent.ModifierFlags = []
    private var hovering = false
    private var messageTimer: Timer?

    static let size = NSSize(width: 168, height: 30)

    override init(frame: NSRect) {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.addSublayer(content)
        glow.cornerRadius = 10
        glow.opacity = 0
        content.addSublayer(glow)
        pill.cornerRadius = 8
        pill.borderWidth = 1
        content.addSublayer(pill)
        message.alignmentMode = .center
        message.fontSize = 12
        message.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        message.opacity = 0
        content.addSublayer(message)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Keyboard shortcut")
        toolTip = "Click, then press a new shortcut"
        showCaps(shortcut.keyLabels, animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { Self.size }
    override var acceptsFirstResponder: Bool { true }
    override func isAccessibilityElement() -> Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isFlipped: Bool { false }

    override func accessibilityValue() -> Any? { isRecording ? "Recording" : shortcut.displayString }
    override func accessibilityPerformPress() -> Bool { startRecording(); return true }

    // MARK: Layout & colors

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.bounds = bounds
        content.position = CGPoint(x: bounds.midX, y: bounds.midY)
        pill.frame = bounds
        glow.frame = bounds.insetBy(dx: -3, dy: -3)
        message.frame = CGRect(x: 6, y: (bounds.height - 16) / 2, width: bounds.width - 12, height: 16)
        message.contentsScale = window?.backingScaleFactor ?? 2
        layoutCaps()
        CATransaction.commit()
        updateColors()
    }

    private func layoutCaps() {
        let gap: CGFloat = 4
        let total = caps.reduce(0) { $0 + $1.width } + gap * CGFloat(max(caps.count - 1, 0))
        var x = (bounds.width - total) / 2
        for cap in caps {
            cap.bounds = CGRect(x: 0, y: 0, width: cap.width, height: KeyCapLayer.height)
            cap.position = CGPoint(x: x + cap.width / 2, y: bounds.midY)
            cap.contentsScale = window?.backingScaleFactor ?? 2
            x += cap.width + gap
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let accent = NSColor.controlAccentColor
            pill.backgroundColor = (isRecording ? accent.withAlphaComponent(0.10)
                                    : hovering ? NSColor.secondarySystemFill : NSColor.tertiarySystemFill).cgColor
            pill.borderColor = (isRecording ? accent : NSColor.separatorColor).cgColor
            pill.borderWidth = isRecording ? 1.5 : 1
            glow.backgroundColor = accent.withAlphaComponent(0.28).cgColor
            message.foregroundColor = NSColor.secondaryLabelColor.cgColor
            caps.forEach { $0.updateColors() }
        }
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .cursorUpdate],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; animateColors() }
    override func mouseExited(with event: NSEvent) { hovering = false; animateColors() }
    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }

    override func mouseDown(with event: NSEvent) {
        // A press-in: the pill dips a touch, like a key.
        let dip = CABasicAnimation(keyPath: "transform.scale")
        dip.fromValue = 1; dip.toValue = 0.96; dip.duration = 0.08
        dip.autoreverses = true
        dip.timingFunction = CAMediaTimingFunction(name: .easeOut)
        content.add(dip, forKey: "dip")
        isRecording ? cancel() : startRecording()
    }

    private func animateColors() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        updateColors()
        CATransaction.commit()
    }

    // MARK: Recording

    func startRecording() {
        guard !isRecording else { return }
        window?.makeFirstResponder(self)
        isRecording = true
        heldModifiers = []
        showPrompt("Type shortcut…")
        animateColors()
        // A slow breathing glow while it listens.
        glow.opacity = 1
        let breathe = CABasicAnimation(keyPath: "opacity")
        breathe.fromValue = 0.35; breathe.toValue = 1
        breathe.duration = 0.9
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        glow.add(breathe, forKey: "breathe")

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown]) { [weak self] event in
            let swallow = MainActor.assumeIsolated { self?.swallows(event) ?? false }
            return swallow ? nil : event
        }
    }

    func stopRecording(resigning: Bool = false) {
        guard isRecording else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
        glow.removeAnimation(forKey: "breathe")
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = glow.presentation()?.opacity ?? 1; fade.toValue = 0; fade.duration = 0.2
        glow.opacity = 0
        glow.add(fade, forKey: "fade")
        animateColors()
        if !resigning, window?.firstResponder === self { window?.makeFirstResponder(nil) }
    }

    /// True when the event was ours (it doesn't go on to the window).
    private func swallows(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown:
            // A click anywhere else cancels; a click on us is handled by mouseDown.
            if event.window !== window || !bounds.contains(convert(event.locationInWindow, from: nil)) {
                cancel()
            }
            return false
        case .flagsChanged:
            let mods = event.modifierFlags.intersection(.relevant)
            guard mods != heldModifiers else { return true }
            heldModifiers = mods
            if mods.isEmpty { showPrompt("Type shortcut…") } else { showCaps(Shortcut.modifierLabels(mods), animated: true, ghost: true) }
            return true
        case .keyDown:
            let mods = event.modifierFlags.intersection(.relevant)
            if mods.isEmpty, event.keyCode == UInt16(kVK_Escape) { cancel(); return true }
            if mods.isEmpty, event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete) {
                commit(.standard) // ⌫ puts the default back
                return true
            }
            let candidate = Shortcut(keyCode: event.keyCode, modifiers: mods)
            guard candidate.isValid else {
                reject("Add ⌘, ⌥ or ⌃")
                return true
            }
            if candidate != shortcut, candidate.takenByMacOS {
                reject("Taken by macOS")
                return true
            }
            commit(candidate)
            return true
        default:
            return false
        }
    }

    private func cancel(resigning: Bool = false) {
        stopRecording(resigning: resigning)
        showCaps(shortcut.keyLabels, animated: true)
    }

    private func commit(_ candidate: Shortcut) {
        if candidate != shortcut, onChange?(candidate) == false {
            reject("Can't use that one")
            return
        }
        shortcut = candidate // while still recording, so didSet leaves the caps to us
        stopRecording()
        showCaps(candidate.keyLabels, animated: true)
        flashSuccess()
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    /// Shakes with a reason, outside of recording (the reset arrow when ⇧⌘Space is taken).
    func refuse(_ text: String) {
        reject(text)
        messageTimer?.invalidate()
        messageTimer = Timer.scheduledTimer(withTimeInterval: 1.4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isRecording else { return }
                self.showCaps(self.shortcut.keyLabels, animated: true)
            }
        }
    }

    private func reject(_ text: String) {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        NSSound.beep()
        let shake = CAKeyframeAnimation(keyPath: "position.x")
        shake.values = [0, -7, 6, -4, 3, -1, 0]
        shake.keyTimes = [0, 0.15, 0.35, 0.55, 0.72, 0.88, 1]
        shake.duration = 0.4
        shake.isAdditive = true
        content.add(shake, forKey: "shake")
        showPrompt(text, tint: .systemRed)
        heldModifiers = []
        messageTimer?.invalidate()
        messageTimer = Timer.scheduledTimer(withTimeInterval: 1.4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRecording, self.heldModifiers.isEmpty else { return }
                self.showPrompt("Type shortcut…")
            }
        }
    }

    /// The border blooms green for a beat, then settles back.
    private func flashSuccess() {
        let flash = CABasicAnimation(keyPath: "borderColor")
        flash.fromValue = NSColor.systemGreen.cgColor
        flash.toValue = pill.borderColor
        flash.duration = 0.6
        flash.timingFunction = CAMediaTimingFunction(name: .easeOut)
        pill.add(flash, forKey: "flash")
        let fill = CABasicAnimation(keyPath: "backgroundColor")
        fill.fromValue = NSColor.systemGreen.withAlphaComponent(0.16).cgColor
        fill.toValue = pill.backgroundColor
        fill.duration = 0.6
        fill.timingFunction = CAMediaTimingFunction(name: .easeOut)
        pill.add(fill, forKey: "fill")
    }

    // MARK: Content

    private func showPrompt(_ text: String, tint: NSColor? = nil) {
        clearCaps(animated: true)
        message.string = text
        effectiveAppearance.performAsCurrentDrawingAppearance {
            message.foregroundColor = (tint ?? .secondaryLabelColor).cgColor
        }
        message.removeAllAnimations()
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = message.presentation()?.opacity ?? 0; fade.toValue = 1; fade.duration = 0.18
        message.opacity = 1
        message.add(fade, forKey: "in")
    }

    private func hidePrompt() {
        guard message.opacity > 0 else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = message.presentation()?.opacity ?? 1; fade.toValue = 0; fade.duration = 0.12
        message.opacity = 0
        message.add(fade, forKey: "out")
    }

    private func clearCaps(animated: Bool) {
        let old = caps
        caps = []
        for cap in old {
            guard animated else { cap.removeFromSuperlayer(); continue }
            CATransaction.begin()
            CATransaction.setCompletionBlock { cap.removeFromSuperlayer() }
            let out = CABasicAnimation(keyPath: "opacity")
            out.fromValue = 1; out.toValue = 0; out.duration = 0.12
            cap.opacity = 0
            cap.add(out, forKey: "out")
            CATransaction.commit()
        }
    }

    /// `ghost`: modifiers being held mid-recording, drawn lighter until a key completes them.
    private func showCaps(_ labels: [String], animated: Bool, ghost: Bool = false) {
        // Holding more modifiers: keep the caps already up and only pop in the new ones.
        let previous = caps.map(\.label)
        let reuse = ghost && caps.allSatisfy(\.ghost) && !caps.isEmpty
        hidePrompt()
        if !reuse { clearCaps(animated: animated) } else { caps.forEach { $0.removeFromSuperlayer() } ; caps = [] }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        caps = labels.map { label in
            let cap = KeyCapLayer(label: label, ghost: ghost)
            content.addSublayer(cap)
            return cap
        }
        effectiveAppearance.performAsCurrentDrawingAppearance { caps.forEach { $0.updateColors() } }
        layoutCaps()
        CATransaction.commit()

        guard animated else { return }
        var delay: CFTimeInterval = 0
        for cap in caps where !(reuse && previous.contains(cap.label)) {
            let pop = CASpringAnimation(keyPath: "transform.scale")
            pop.fromValue = 0.55; pop.toValue = 1
            pop.mass = 0.6; pop.stiffness = 320; pop.damping = 14
            pop.duration = pop.settlingDuration
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0; fade.toValue = cap.opacity; fade.duration = 0.14
            let rise = CASpringAnimation(keyPath: "position.y")
            rise.fromValue = cap.position.y - 4; rise.toValue = cap.position.y
            rise.mass = 0.6; rise.stiffness = 320; rise.damping = 14
            rise.duration = rise.settlingDuration
            let group = CAAnimationGroup()
            group.animations = [pop, fade, rise]
            group.duration = max(pop.duration, rise.duration)
            group.beginTime = CACurrentMediaTime() + delay
            group.fillMode = .backwards
            cap.add(group, forKey: "pop")
            delay += ghost ? 0 : 0.035
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { stopRecording() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func resignFirstResponder() -> Bool {
        if isRecording { cancel(resigning: true) }
        return super.resignFirstResponder()
    }

    private var resignObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        guard let window else { return }
        // Switching apps mid-recording: give the old shortcut back.
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.isRecording == true { self?.cancel() } }
        }
    }
}

/// One keycap: a rounded key with a lighter top face and a darker lip at the bottom.
@MainActor
final class KeyCapLayer: CALayer {
    static let height: CGFloat = 20
    let label: String
    let ghost: Bool
    let width: CGFloat
    private let face = CALayer()
    private let text = CATextLayer()
    private static let font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)

    init(label: String, ghost: Bool) {
        self.label = label
        self.ghost = ghost
        let textWidth = (label as NSString).size(withAttributes: [.font: Self.font]).width
        width = max(Self.height + 2, ceil(textWidth) + 12)
        super.init()
        cornerRadius = 5
        face.cornerRadius = 5
        addSublayer(face)
        text.string = label
        text.font = Self.font
        text.fontSize = Self.font.pointSize
        text.alignmentMode = .center
        face.addSublayer(text)
        opacity = ghost ? 0.55 : 1
        shadowOpacity = 1
        shadowRadius = 0.5
        shadowOffset = CGSize(width: 0, height: -0.5)
    }

    override init(layer: Any) {
        let other = layer as! KeyCapLayer
        label = other.label; ghost = other.ghost; width = other.width
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var contentsScale: CGFloat {
        didSet { text.contentsScale = contentsScale; face.contentsScale = contentsScale }
    }

    override func layoutSublayers() {
        super.layoutSublayers()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The face sits 1.5pt up from the bottom, so the darker base shows as a lip.
        face.frame = CGRect(x: 0, y: 1.5, width: bounds.width, height: bounds.height - 1.5)
        let lineHeight = ceil(Self.font.ascender - Self.font.descender)
        text.frame = CGRect(x: 0, y: (face.bounds.height - lineHeight) / 2, width: face.bounds.width, height: lineHeight)
        CATransaction.commit()
    }

    /// Call inside `performAsCurrentDrawingAppearance`.
    func updateColors() {
        let dark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        backgroundColor = (dark ? NSColor(white: 0.08, alpha: 1) : NSColor(white: 0.72, alpha: 1)).cgColor
        face.backgroundColor = (dark ? NSColor(white: 0.30, alpha: 1) : NSColor(white: 0.995, alpha: 1)).cgColor
        face.borderWidth = 0.5
        face.borderColor = (dark ? NSColor(white: 1, alpha: 0.10) : NSColor(white: 0, alpha: 0.08)).cgColor
        shadowColor = NSColor(white: 0, alpha: dark ? 0.5 : 0.18).cgColor
        text.foregroundColor = NSColor.labelColor.cgColor
    }
}
