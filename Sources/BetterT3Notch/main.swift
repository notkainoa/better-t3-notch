import AppKit
import Carbon.HIToolbox
import Combine
import ServiceManagement

/// Non-activating: it can take keyboard focus (for the shortcut and the reply field)
/// without pulling the user's current app out of the foreground.
final class NotchPanel: NSPanel {
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    weak var gestures: NotchGestures?
    /// A press over the notch, held back until it's clear whether it's a click or a drag, with
    /// what the notch showed and what was pressed when it went down.
    private var press: (down: NSEvent, swipe: DragSwipe, target: SwipeTarget, pressed: NSView?)?
    var isPressing: Bool { press != nil }

    /// Press-and-drag swipes. A press is held back (rows and cards act the moment they're
    /// pressed), then either replayed as the click it was or turned into a swipe.
    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            // A press still held means its release never came here: start over from this one.
            cancelPress()
            let p = screenPoint(event)
            guard let target = gestures?.swipeTarget(at: p) else { break }
            press = (event, DragSwipe(at: p, toward: target.direction), target, pressed(event))
            return
        case .leftMouseDragged where press != nil:
            if let along = press?.swipe.move(to: screenPoint(event)), let direction = press?.swipe.direction {
                gestures?.swipeMoved(along, toward: direction)
            }
            return
        case .leftMouseUp where press != nil:
            guard let (down, held, target, pressed) = press else { break }
            press = nil
            var swipe = held
            var outcome = swipe.end(at: screenPoint(event))
            // The notch changed under the press (a card came or went, the list closed): a swipe
            // or a click would act on something that wasn't there, so it does nothing. A click also
            // needs the same thing under it (not a row that slid in, or an Approve button that
            // appeared); a swipe replays nothing, so the list shifting under it doesn't matter.
            if gestures?.swipeTarget(at: swipe.start) != target
                || (outcome == .click && self.pressed(down) !== pressed) { outcome = .cancel }
            if outcome == .click {
                // The click it was: the release goes first in line, so a button that tracks the
                // press (and waits for its release) gets it, then the press itself.
                NSApp.postEvent(event, atStart: true)
                super.sendEvent(down)
            }
            gestures?.swipeEnded(outcome == .swipe, toward: swipe.direction)
            return
        default:
            break
        }
        super.sendEvent(event)
    }

    /// Drop a held press without acting on it (its release went missing).
    func cancelPress() {
        guard let held = press else { return }
        press = nil
        gestures?.swipeEnded(false, toward: held.swipe.direction)
    }

    /// What a click at this spot would act on right now: the button under it, or else the row,
    /// card or footer it's in (the labels inside a row shift a little as it updates; labels are
    /// NSControls too, so it looks for buttons, not controls).
    private func pressed(_ event: NSEvent) -> NSView? {
        Self.clickTarget(of: contentView?.hitTest(event.locationInWindow))
    }

    static func clickTarget(of hit: NSView?) -> NSView? {
        var view = hit
        while let v = view, !(v is NSButton || v is PressTarget) { view = v.superview }
        return view
    }

    private func screenPoint(_ event: NSEvent) -> CGPoint {
        convertPoint(toScreen: event.locationInWindow)
    }
}

/// A view that acts on a click as a whole (a row, a card, the footer, the closed notch).
protocol PressTarget: AnyObject {}

/// What a swipe at some point would act on: which way does something, and what's showing.
struct SwipeTarget: Equatable {
    var direction: SwipeTracker.Direction
    /// `.idle` for any closed notch: work starting or settling under a click doesn't change it.
    var mode: NotchMode
    /// The pop-up's thread, so one card swapped for another under a press counts as a change.
    var eventId: String?
}

@MainActor
protocol NotchGestures: AnyObject {
    /// What a press-and-drag at `p` (screen) would act on; nil lets the press through untouched
    /// (not over the notch, or typing a reply).
    func swipeTarget(at p: CGPoint) -> SwipeTarget?
    func swipeMoved(_ along: CGFloat, toward direction: SwipeTracker.Direction)
    func swipeEnded(_ swiped: Bool, toward direction: SwipeTracker.Direction)
}

private let forceExpanded = ProcessInfo.processInfo.environment["T3NOTCH_FORCE_EXPANDED"] != nil

/// One notch window pinned to the top-center of a single display.
@MainActor
final class NotchController: NotchGestures {
    let screen: NSScreen
    private let panel: NotchPanel
    private let model: NotchModel
    private var collapseWork: DispatchWorkItem?
    private var cancellables: Set<AnyCancellable> = []
    private var resignObserver: NSObjectProtocol?
    private var lastRenderKey: [AnyHashable] = []
    private let root: NotchRootView
    private let store: ThreadStore

    /// Window is sized for the largest state; the visible notch is drawn inside it.
    private static let canvas = CGSize(width: 700, height: NotchModel.maxHeight)

    /// Swiped away: hovering doesn't open it again until the cursor has left the notch.
    private var swipedAway = false
    /// Swiped open: a drag down can let go past a short list, so leaving it doesn't close it
    /// until this (uptime) has passed.
    private var swipeHeldUntil: TimeInterval?
    private var staleCheckPending = false

    init(screen: NSScreen, store: ThreadStore, onSettings: @escaping () -> Void) {
        self.screen = screen
        self.store = store
        model = NotchModel(notchSize: Self.notchSize(on: screen), hardwareNotch: screen.safeAreaInsets.top > 0, store: store)
        model.onSettings = onSettings

        let canvas = Self.canvas
        let f = screen.frame
        panel = NotchPanel(
            contentRect: .init(x: f.midX - canvas.width / 2, y: f.maxY - canvas.height,
                               width: canvas.width, height: canvas.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isReleasedWhenClosed = false // ARC owns it; AppKit's extra release would over-free
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .init(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.ignoresMouseEvents = true
        // Hover rows / collapse on exit need mouse moves *inside* the panel too. SwiftUI used to
        // turn this on implicitly via its tracking areas; plain AppKit windows default to off.
        panel.acceptsMouseMovedEvents = true
        // Invisible to screen sharing, recordings and screenshots, so thread titles, commands and
        // agent messages never leak into a Zoom/Meet share. It stays visible on your own display.
        panel.sharingType = Settings.hideFromCapture ? .none : .readOnly // see applyCaptureSetting()
        root = NotchRootView(model: model, store: store)
        panel.contentView = root
        root.onSwipeAway = { [weak self] in self?.swipeAway() }
        root.onSwipeOpen = { [weak self] in self?.swipeOpen() }
        // Two fingers follow the same rules as a press, and wait while a press is held (it would
        // replay onto whatever the swipe left behind).
        root.swipeDirection = { [weak self] in
            guard let self, !self.panel.isPressing else { return nil }
            return self.swipeTarget(at: NSEvent.mouseLocation)?.direction
        }
        panel.gestures = self
        // Scrolling doesn't move the pointer, so nothing re-checks what's under it: without this
        // the closed notch's empty canvas kept eating the next scroll until the mouse moved.
        root.onSwipeSettled = { [weak self] in self?.updateHover(NSEvent.mouseLocation) }
        panel.orderFrontRegardless()

        // Re-render when store changes so `model.mode` (derived) is re-evaluated.
        // objectWillChange fires *before* the change; compare after it lands, and only redraw
        // a collapsed notch when what it shows actually changed.
        store.objectWillChange.receive(on: RunLoop.main).sink { [weak self] in
            guard let self else { return }
            if self.root.isInteractive {
                self.root.refresh() // open: update the list / card (you're looking at it)
                return
            }
            let key = self.model.renderKey
            if key != self.lastRenderKey {
                self.lastRenderKey = key
                self.root.refresh() // collapsed: only when something visible changed
                // The pill may have grown under a cursor that isn't moving: make it clickable now.
                self.updateHover(NSEvent.mouseLocation)
            }
        }.store(in: &cancellables)
        // Hover, keyboard, reply, mode: reshape (spring) and mount/unmount the list or card.
        model.objectWillChange.receive(on: RunLoop.main).sink { [weak self] in
            self?.root.refresh()
        }.store(in: &cancellables)
        // Opening T3 Code from the notch (a row, the footer, a card): close the notch.
        store.openedT3.receive(on: RunLoop.main).sink { [weak self] in
            self?.unfocus(restoreFocus: false) // T3 comes to the front instead
            self?.collapse()
        }.store(in: &cancellables)
        // Reply field opened by mouse: the panel needs focus for typing.
        model.$replyingTo.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
            guard let self else { return }
            self.syncFocus()
            if !self.model.focused { self.handBackFocus() } // reply sent / cancelled
        }.store(in: &cancellables)
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.unfocus(restoreFocus: false) } // clicked elsewhere
        }
        if forceExpanded { model.hovering = true }
    }

    var isFocused: Bool { model.focused }
    /// Pointer is somewhere this notch could care about (or it still thinks it's hovered).
    func cares(about p: CGPoint) -> Bool {
        model.hovering || model.hoveredRow != nil || model.hoveredFooter || panel.isPressing
            || panel.frame.insetBy(dx: -8, dy: -8).contains(p)
    }
    var peekRow: String? { model.peekRow }

    /// Keyboard mode (shortcut): expand, select the most urgent thread, take focus.
    func focus() {
        model.selection = (store.stickyEvent ?? model.listThreads.first)?.id
        model.keyboard = true
        syncFocus()
    }

    /// App that was frontmost before we took focus; it gets focus back when we close.
    private var previousApp: NSRunningApplication?

    func unfocus(restoreFocus: Bool = true) {
        guard model.focused else { return }
        model.keyboard = false
        model.replyingTo = nil
        model.draft = ""
        model.hovering = false
        syncFocus()
        if restoreFocus { handBackFocus() }
        previousApp = nil
    }

    private func handBackFocus() {
        previousApp?.activate()
        previousApp = nil
    }

    private func syncFocus() {
        if model.focused {
            panel.allowsKey = true
            panel.ignoresMouseEvents = false
            // Keys only reach an *active* app, so take focus like Spotlight does.
            if !NSApp.isActive {
                previousApp = NSWorkspace.shared.frontmostApplication
                NSApp.activate()
            }
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.allowsKey = false
            if panel.isKeyWindow { panel.resignKey() }
            panel.orderFrontRegardless()
        }
    }

    /// Returns true when the key was handled (and shouldn't reach the text field).
    func handleKey(_ event: NSEvent) -> Bool {
        guard model.focused else { return false }
        let key = Int(event.keyCode)
        if key == kVK_Escape {
            if model.replyingTo != nil && model.keyboard {
                model.replyingTo = nil // back to the list
            } else {
                unfocus()
            }
            return true
        }
        guard model.replyingTo == nil else { return false } // typing: let the field have it
        guard let thread = model.selectedThread else { return false }

        switch key {
        case kVK_UpArrow: model.moveSelection(-1)
        case kVK_DownArrow: model.moveSelection(1)
        case kVK_Return, kVK_ANSI_KeypadEnter:
            unfocus(restoreFocus: false) // T3 Code comes to the front instead
            store.open(thread)
        default:
            let char = event.charactersIgnoringModifiers?.lowercased() ?? ""
            switch (char, thread.request?.kind) {
            case ("r", _):
                model.startReply(thread)
            case ("a", .approval(_, _, let options)?):
                if let option = options.first(where: \.isAccept) { store.approve(thread, option) }
            case ("d", .approval(_, _, let options)?):
                if let option = options.first(where: { !$0.isAccept }) { store.approve(thread, option) }
            case (let c, _) where Int(c).map { (1...9).contains($0) } == true:
                let i = Int(c)! - 1
                if case .approval(_, _, let options)? = thread.request?.kind, options.indices.contains(i) {
                    store.approve(thread, options[i])
                } else if let q = thread.request?.quickQuestion, q.options.indices.contains(i) {
                    store.answer(thread, q, q.options[i])
                }
            default:
                return false
            }
        }
        return true
    }

    func collapse() {
        model.holdOpen = false
        swipeHeldUntil = nil
        model.hovering = false
    }

    /// Swiped up on the open list or a pop-up: back to the pill, and nothing opens. A pop-up goes
    /// the way its close button sends it (a "needs you" card keeps its island).
    func swipeAway() {
        unfocus() // keyboard / reply mode: same as Esc
        // A card under the cursor counts as hovered: without this the list would open in its place.
        collapseWork?.cancel()
        collapseWork = nil
        collapse()
        store.dismissEvent()
        swipedAway = true
    }

    /// Swiped down on the closed notch (two fingers, or press and drag): open the list, as a
    /// click does.
    func swipeOpen() {
        swipedAway = false
        swipeHeldUntil = ProcessInfo.processInfo.systemUptime + 1
        model.hovering = true
    }

    func swipeTarget(at p: CGPoint) -> SwipeTarget? {
        guard !forceExpanded, model.replyingTo == nil,
              visibleRect().insetBy(dx: -4, dy: -4).contains(p) else { return nil }
        let mode = model.mode
        let open = mode == .expanded || mode == .peek
        return SwipeTarget(direction: open ? .up : .down, mode: open ? mode : .idle,
                           eventId: mode == .peek ? store.eventId : nil)
    }

    func swipeMoved(_ along: CGFloat, toward direction: SwipeTracker.Direction) {
        if direction == .up { root.follow(along) }
    }

    func swipeEnded(_ swiped: Bool, toward direction: SwipeTracker.Direction) {
        root.follow(0)
        if swiped {
            if direction == .up { swipeAway() } else { swipeOpen() }
        }
        updateHover(NSEvent.mouseLocation) // hover was paused while the button was held
    }

    /// Display changes rebuild every notch; tear this one down completely.
    /// Invisible to screen sharing / recordings / screenshots, or not (menu: Visible in Screen Sharing).
    /// Takes effect immediately; the window server re-evaluates the window on the next capture.
    func applyCaptureSetting() {
        panel.sharingType = Settings.hideFromCapture ? .none : .readOnly
    }

    func close() {
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        collapseWork?.cancel()
        cancellables.removeAll()
        panel.contentView = nil
        panel.orderOut(nil)
        panel.close()
    }

    /// Screen-space rect of the currently visible notch shape.
    private func visibleRect() -> CGRect {
        let s = model.size
        let f = panel.frame
        return .init(x: f.midX - s.width / 2, y: f.maxY - s.height, width: s.width, height: s.height)
    }

    func updateHover(_ p: CGPoint) {
        if forceExpanded { return }
        // Held down over the notch (a click or a drag): it stays as it is until let go.
        if panel.isPressing {
            // Unless the release went missing (Mission Control, a screen lock): if the button is
            // still up a moment from now, the release isn't just waiting in line, so drop it.
            if NSEvent.pressedMouseButtons & 1 == 0, !staleCheckPending {
                staleCheckPending = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self else { return }
                    self.staleCheckPending = false
                    if NSEvent.pressedMouseButtons & 1 == 0 { self.panel.cancelPress() }
                }
            }
            return
        }
        // Slight slop so slamming the cursor into the top edge opens it.
        let rect = visibleRect()
        let inside = rect.insetBy(dx: -4, dy: -4).contains(p)
        let row = inside ? model.rowId(atY: rect.maxY - p.y) : nil
        if model.hoveredRow != row { model.hoveredRow = row }
        let footer = inside && model.isFooter(atY: rect.maxY - p.y)
        if model.hoveredFooter != footer { model.hoveredFooter = footer }
        if model.focused { return } // keyboard / reply mode: stays open until Esc or click-away
        panel.ignoresMouseEvents = !inside // takes the click that opens it

        if inside {
            collapseWork?.cancel()
            collapseWork = nil
            // Otherwise a click opens it (NotchRootView.mouseDown).
            if Settings.openOnHover, !model.hovering, !swipedAway { model.hovering = true }
            return
        }
        swipedAway = false
        if model.hovering, collapseWork == nil, !model.holdOpen {
            let work = DispatchWorkItem { [weak self] in
                self?.model.hovering = false
                self?.collapseWork = nil
            }
            collapseWork = work
            let held = max(0, (swipeHeldUntil ?? 0) - ProcessInfo.processInfo.systemUptime)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25 + held, execute: work)
        }
    }

    static func notchSize(on screen: NSScreen) -> CGSize {
        guard screen.safeAreaInsets.top > 0,
              let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea
        else {
            // No hardware notch: fake one hanging from the menu bar.
            let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
            return .init(width: 190, height: max(menuBar, 24))
        }
        return .init(width: screen.frame.width - left.width - right.width + 4,
                     height: screen.safeAreaInsets.top)
    }
}

/// Which display(s) get a notch. Persisted as a string in UserDefaults.
enum DisplayChoice: Equatable {
    case all, builtIn, named(String)

    private static let key = "displayChoice"

    static var saved: DisplayChoice {
        get {
            switch UserDefaults.standard.string(forKey: key) {
            case nil, "all": .all
            case "builtin": .builtIn
            case let name?: .named(String(name.dropFirst("name:".count)))
            }
        }
        set {
            let raw = switch newValue {
            case .all: "all"
            case .builtIn: "builtin"
            case .named(let n): "name:\(n)"
            }
            UserDefaults.standard.set(raw, forKey: key)
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
    var isBuiltIn: Bool { CGDisplayIsBuiltin(displayID) != 0 }

    static var builtIn: NSScreen {
        screens.first(where: \.isBuiltIn) ?? screens.first { $0.safeAreaInsets.top > 0 } ?? main ?? screens[0]
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation, SettingsHost {
    let store = ThreadStore()
    private var controllers: [NotchController] = []
    private var monitors: [Any] = []
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled",
                                           accessibilityDescription: "Better T3 Notch")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        Theme.start() // before the first panels, so they open already matching T3
        rebuildPanels()
        NotificationCenter.default.addObserver(forName: Theme.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildPanels() } // views take their colors when built
        }

        let handler: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                let p = NSEvent.mouseLocation
                // Most mouse moves are nowhere near a notch: skip all work for those.
                guard let self, self.controllers.contains(where: { $0.cares(about: p) }) else { return }
                self.controllers.forEach { $0.updateHover(p) }
                self.syncOutputWatch()
            }
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: handler) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { e in handler(e); return e }) {
            monitors.append(m)
        }
        // Displays plugged/unplugged or rearranged.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildPanels() }
        }

        // Keyboard mode: keys go to whichever notch has focus.
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            let handled = MainActor.assumeIsolated {
                let handled = self?.controllers.first(where: \.isFocused)?.handleKey(event) ?? false
                self?.syncOutputWatch() // selection may have moved
                return handled
            }
            return handled ? nil : event
        }) {
            monitors.append(m)
        }
        registerShortcut(Shortcut.saved)

        // New command started (or finished) under the cursor: follow it.
        store.$threads.receive(on: RunLoop.main).sink { [weak self] _ in self?.syncOutputWatch() }
            .store(in: &cancellables)

        store.start()
        Updater.start()
        // Screenshots / testing: put the Settings window up without taking focus.
        if let tab = ProcessInfo.processInfo.environment["T3NOTCH_OPEN_SETTINGS"] {
            settings.show(tab: Int(tab), activate: false)
        }
    }

    private var hotKey: HotKey?

    @discardableResult
    private func registerShortcut(_ shortcut: Shortcut?) -> Bool {
        hotKey = nil // let go of the old one first: the new one may be the same keys
        guard let shortcut else { return true } // cleared: no shortcut at all
        hotKey = HotKey(shortcut) { [weak self] in self?.toggleKeyboardMode() }
        return hotKey != nil
    }
    private var cancellables: Set<AnyCancellable> = []

    /// One live command-output stream, for whichever notch is peeking at a running row.
    private func syncOutputWatch() {
        store.watchOutput(of: controllers.lazy.compactMap(\.peekRow).first)
    }

    /// The keyboard shortcut (⇧⌘Space unless changed or cleared in Settings): open the notch under the mouse (or the first one), or close it.
    private func toggleKeyboardMode() {
        if let focused = controllers.first(where: \.isFocused) {
            focused.unfocus()
            return
        }
        let mouse = NSEvent.mouseLocation
        let target = controllers.first { $0.screen.frame.contains(mouse) } ?? controllers.first
        target?.focus()
    }

    /// Chosen display, falling back to the built-in (laptop) screen when it isn't connected.
    private func targetScreens() -> [NSScreen] {
        switch DisplayChoice.saved {
        case .all: NSScreen.screens
        case .builtIn: [NSScreen.builtIn]
        case .named(let name): [NSScreen.screens.first { $0.localizedName == name } ?? NSScreen.builtIn]
        }
    }

    private func rebuildPanels() {
        controllers.forEach { $0.close() }
        controllers = targetScreens().map { screen in
            NotchController(screen: screen, store: store) { [weak self] in self?.showSettings(from: screen) }
        }
    }

    // MARK: Settings (window, plus a short status item menu)

    private lazy var settings = SettingsWindowController(host: self)

    private func buildMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        if let problem = store.incompatible {
            let warn = NSMenuItem(title: "⚠︎ Needs an update: \(problem)", action: nil, keyEquivalent: "")
            warn.isEnabled = false
            menu.addItem(warn)
            menu.addItem(.separator())
        }
        let prefs = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)
        let open = NSMenuItem(title: "Open T3 Code", action: #selector(openT3), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        if Updater.isAvailable {
            let update = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
            update.target = self
            menu.addItem(update)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Better T3 Notch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func openSettings() { settings.show() }
    @objc private func checkForUpdates() { Updater.checkNow() }

    // Greyed out while Sparkle can't start a check (one is already running), as Sparkle recommends.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.action == #selector(checkForUpdates) ? Updater.canCheck : true
    }


    private func showSettings(from screen: NSScreen) {
        controllers.forEach { $0.collapse() }
        settings.show()
    }

    func menuNeedsUpdate(_ menu: NSMenu) { buildMenu(menu) }

    // MARK: SettingsHost

    func displayChanged() {
        DispatchQueue.main.async { self.rebuildPanels() }
    }

    func captureChanged() {
        controllers.forEach { $0.applyCaptureSetting() }
    }

    func setShortcut(_ shortcut: Shortcut?) -> Bool {
        guard registerShortcut(shortcut) else {
            // Taken: keep the old one, but stay out of the way while the recorder is still listening.
            if recordingShortcut { hotKey = nil } else { registerShortcut(Shortcut.saved) }
            return false
        }
        Shortcut.saved = shortcut
        return true
    }

    func shortcutRecording(_ recording: Bool) {
        // While recording, the live shortcut steps aside so pressing it again can be captured.
        recordingShortcut = recording
        if recording { hotKey = nil } else if hotKey == nil { registerShortcut(Shortcut.saved) }
    }

    private var recordingShortcut = false

    func panelsNeedRebuild() {
        DispatchQueue.main.async { self.rebuildPanels() }
    }

    func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
                if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Launch at Login"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc func openT3() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: ThreadStore.t3BundleId) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
