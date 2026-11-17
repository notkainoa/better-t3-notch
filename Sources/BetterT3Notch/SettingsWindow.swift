import AppKit
import Combine
import ServiceManagement

/// What the Settings window changes outside of `Settings` / UserDefaults.
@MainActor
protocol SettingsHost: AnyObject {
    var store: ThreadStore { get }
    func displayChanged()
    func captureChanged()
    func panelsNeedRebuild()
    func toggleLaunchAtLogin()
    func openT3()
}

/// A real window, macOS-style: toolbar tabs over grouped rows of switches. The notch is a
/// non-activating panel that collapses when the cursor leaves, which is no place for a form.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private weak var host: SettingsHost?
    private var window: NSWindow?
    private var panes: [SettingsPane] = []
    private var cancellables: Set<AnyCancellable> = []

    init(host: SettingsHost) {
        self.host = host
        super.init()
    }

    /// `activate: false` puts it up without taking focus (screenshots, `T3NOTCH_OPEN_SETTINGS`).
    func show(tab: Int? = nil, activate: Bool = true) {
        let window = self.window ?? makeWindow()
        if let tab, let tabs = window.contentViewController as? NSTabViewController, tabs.tabViewItems.indices.contains(tab) {
            tabs.selectedTabViewItemIndex = tab
        }
        refresh()
        if !window.isVisible { window.center() }
        if activate {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        }
        window.orderFrontRegardless()
    }

    var isVisible: Bool { window?.isVisible ?? false }

    private func makeWindow() -> NSWindow {
        guard let host else { fatalError("settings without a host") }
        let refresh: () -> Void = { [weak self] in self?.refresh() }
        panes = [
            GeneralPane(host: host, refresh: refresh),
            NotificationsPane(host: host, refresh: refresh),
            AppearancePane(host: host, refresh: refresh),
        ]
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = [.crossfade, .allowUserInteraction]
        for pane in panes {
            let item = NSTabViewItem(viewController: pane)
            item.label = pane.title ?? ""
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
            tabs.addTabViewItem(item)
        }
        let window = SettingsWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.toolbarStyle = .preference
        window.title = "Better T3 Notch Settings"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        self.window = window

        // Things that change behind the window's back.
        host.store.$incompatible.receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh() }.store(in: &cancellables)
        NotificationCenter.default.addObserver(forName: Theme.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        return window
    }

    func refresh() { panes.forEach { $0.refresh() } }

    // Launch at Login can be approved in System Settings while this is open.
    func windowDidBecomeKey(_ notification: Notification) { refresh() }
}

// MARK: - Panes

@MainActor
class SettingsPane: NSViewController {
    static let width: CGFloat = 540
    let symbol: String
    unowned let host: SettingsHost
    let requestRefresh: () -> Void
    private var refreshers: [() -> Void] = []
    private let stack = NSStackView()

    init(title: String, symbol: String, host: SettingsHost, refresh: @escaping () -> Void) {
        self.symbol = symbol
        self.host = host
        self.requestRefresh = refresh
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 22, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        build()
        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: Self.width),
        ])
        view = root
        refresh()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        preferredContentSize = view.fittingSize // the window fits each tab
    }

    /// Subclasses add their sections here.
    func build() {}

    func refresh() { refreshers.forEach { $0() } }

    // MARK: Building blocks

    func section(_ title: String?, footer: String? = nil, _ rows: [NSView]) {
        let group = NSStackView()
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 6
        if let title {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 13, weight: .semibold)
            group.addArrangedSubview(label)
            group.setCustomSpacing(8, after: label)
        }
        let box = GroupBox(rows: rows)
        group.addArrangedSubview(box)
        box.widthAnchor.constraint(equalToConstant: Self.width - 40).isActive = true
        if let footer {
            let note = NSTextField(wrappingLabelWithString: footer)
            note.font = .systemFont(ofSize: 11)
            note.textColor = .secondaryLabelColor
            note.preferredMaxLayoutWidth = Self.width - 60
            group.addArrangedSubview(note)
            group.setCustomSpacing(6, after: box)
            note.setContentHuggingPriority(.required, for: .vertical)
        }
        stack.addArrangedSubview(group)
    }

    func toggle(_ title: String, _ detail: String? = nil, indent: Bool = false, get: @escaping () -> Bool,
                enabled: (() -> Bool)? = nil, set: @escaping (Bool) -> Void) -> NSView {
        let control = NSSwitch()
        control.controlSize = .small
        control.setAccessibilityLabel(title)
        let target = ActionTarget { [weak control, weak self] in
            guard let control else { return }
            set(control.state == .on)
            self?.requestRefresh()
        }
        control.target = target
        control.action = #selector(ActionTarget.fire)
        let row = Row(title: title, detail: detail, control: control, keep: target, reserve: 50, indent: indent)
        refreshers.append { [weak control, weak row] in
            control?.state = get() ? .on : .off
            let on = enabled?() ?? true
            control?.isEnabled = on
            row?.dimmed = !on
        }
        return row
    }

    func popup<T: Equatable>(_ title: String, _ detail: String? = nil, options: @escaping () -> [(String, T)],
                             get: @escaping () -> T, set: @escaping (T) -> Void) -> NSView {
        let control = NSPopUpButton()
        control.controlSize = .regular
        control.setAccessibilityLabel(title)
        var current: [(String, T)] = []
        let target = ActionTarget { [weak control, weak self] in
            guard let control, current.indices.contains(control.indexOfSelectedItem) else { return }
            set(current[control.indexOfSelectedItem].1)
            self?.requestRefresh()
        }
        control.target = target
        control.action = #selector(ActionTarget.fire)
        control.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let row = Row(title: title, detail: detail, control: control, keep: target, reserve: 220)
        refreshers.append { [weak control] in
            guard let control else { return }
            current = options()
            control.removeAllItems()
            control.addItems(withTitles: current.map(\.0))
            let value = get()
            if let i = current.firstIndex(where: { $0.1 == value }) { control.selectItem(at: i) }
        }
        return row
    }

    func button(_ title: String, _ detail: String? = nil, label: @escaping () -> String,
                visible: (() -> Bool)? = nil, action: @escaping () -> Void) -> NSView {
        let control = NSButton(title: "", target: nil, action: nil)
        control.bezelStyle = .push
        let target = ActionTarget { [weak self] in
            action()
            self?.requestRefresh()
        }
        control.target = target
        control.action = #selector(ActionTarget.fire)
        let row = Row(title: title, detail: detail, control: control, keep: target, reserve: 130)
        refreshers.append { [weak control, weak row] in
            control?.title = label()
            row?.isHidden = !(visible?() ?? true)
        }
        return row
    }

    /// A row that only shows text on the right (status, a shortcut).
    func info(_ title: String, _ detail: String? = nil, value: @escaping () -> String) -> NSView {
        let label = NSTextField(labelWithString: "")
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        let row = Row(title: title, detail: detail, control: label, keep: nil, reserve: 160)
        refreshers.append { [weak label] in label?.stringValue = value() }
        return row
    }

    /// Lets a pane hook its own refresh logic in (warnings and the like).
    func onRefresh(_ body: @escaping () -> Void) { refreshers.append(body) }

    func addBanner(_ view: NSView) { stack.addArrangedSubview(view) }
}

@MainActor
final class GeneralPane: SettingsPane {
    init(host: SettingsHost, refresh: @escaping () -> Void) {
        super.init(title: "General", symbol: "gearshape", host: host, refresh: refresh)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func build() {
        let warning = NSTextField(wrappingLabelWithString: "")
        warning.textColor = .systemOrange
        warning.font = .systemFont(ofSize: 12, weight: .medium)
        warning.preferredMaxLayoutWidth = Self.width - 40
        addBanner(warning)
        onRefresh { [weak self, weak warning] in
            let problem = self?.host.store.incompatible
            warning?.stringValue = problem.map { "⚠︎ Needs an update: \($0)" } ?? ""
            warning?.isHidden = problem == nil
        }

        section("Notch", [
            popup("Show the notch on", options: {
                var out: [(String, DisplayChoice)] = [("All displays", .all), ("Built-in display", .builtIn)]
                for screen in NSScreen.screens where !screen.isBuiltIn {
                    out.append((screen.localizedName, .named(screen.localizedName)))
                }
                if case .named(let name) = DisplayChoice.saved, !NSScreen.screens.contains(where: { $0.localizedName == name }) {
                    out.append(("\(name) (disconnected)", .named(name)))
                }
                return out
            }, get: { DisplayChoice.saved }, set: { [unowned self] in
                DisplayChoice.saved = $0
                host.displayChanged()
            }),
            toggle("Open on hover", "Off: click the notch to open the list.",
                   get: { Settings.openOnHover }, set: { Settings.openOnHover = $0 }),
            info("Open from the keyboard", value: { "⌘⇧Space" }),
        ])

        section("Privacy", [
            toggle("Visible in screen sharing and screenshots",
                   "Off: the notch never shows up in Zoom or Meet shares, recordings or screenshots.",
                   get: { !Settings.hideFromCapture }, set: { [unowned self] in
                       Settings.hideFromCapture = !$0
                       host.captureChanged()
                   }),
        ])

        section("Startup", [
            toggle("Launch at login", get: { SMAppService.mainApp.status == .enabled }, set: { [unowned self] _ in
                host.toggleLaunchAtLogin()
            }),
            button("Waiting for approval", "Allow Better T3 Notch under Login Items in System Settings.",
                   label: { "Open System Settings" }, visible: { SMAppService.mainApp.status == .requiresApproval },
                   action: { SMAppService.openSystemSettingsLoginItems() }),
        ])
    }
}

@MainActor
final class NotificationsPane: SettingsPane {
    init(host: SettingsHost, refresh: @escaping () -> Void) {
        super.init(title: "Notifications", symbol: "bell.badge", host: host, refresh: refresh)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func build() {
        section("Pop-ups", footer: "Turned-off pop-ups still show in the notch's count and list.", [
            toggle("When a run finishes", "Its final message drops down for a few seconds.",
                   get: { Settings.popDone }, set: { [unowned self] in Settings.popDone = $0; host.store.popUpSettingsChanged() }),
            toggle("When a run fails", "The error drops down for a few seconds.",
                   get: { Settings.popFailed }, set: { [unowned self] in Settings.popFailed = $0; host.store.popUpSettingsChanged() }),
            toggle("When an agent needs you", "The approval or question card stays down until you answer.",
                   get: { Settings.popNeedsYou }, set: { [unowned self] in Settings.popNeedsYou = $0; host.store.popUpSettingsChanged() }),
        ])

        let sounds: [(Settings.SoundEvent, String, String?, Chime.Sound)] = [
            (.done, "Run finished", nil, .done),
            (.failed, "Run failed", nil, .failed),
            (.needsYou, "Agent needs you", nil, .needsYou),
            (.pullRequest, "Pull request news", "Checks turn red, or a review comes in.", .needsYou),
            (.limitReset, "Usage limit resets", nil, .done),
        ]
        var rows = [toggle("Play sounds", get: { Chime.enabled }, set: {
            Chime.enabled = $0
            if $0 { Chime.shared.play(.done) } // a little preview
        })]
        for (event, title, detail, sound) in sounds {
            rows.append(toggle(title, detail, indent: true, get: { Settings.sound(event) }, enabled: { Chime.enabled }, set: {
                Settings.setSound(event, $0)
                if $0 { Chime.shared.play(sound) }
            }))
        }
        section("Sounds", rows)
    }
}

@MainActor
final class AppearancePane: SettingsPane {
    init(host: SettingsHost, refresh: @escaping () -> Void) {
        super.init(title: "Appearance", symbol: "paintpalette", host: host, refresh: refresh)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func build() {
        section("Look", [
            popup("Theme", "Match T3 Code follows the palette you pick there.", options: {
                [("Match T3 Code (\(Theme.detected.label))", ThemeChoice.matchT3)]
                    + ([NotchTheme.classic] + NotchTheme.t3).map { ($0.label, ThemeChoice.fixed($0.id)) }
            }, get: { ThemeChoice.saved }, set: { choice in
                // Saved now, so the popup's refresh shows it; applied after the popup's menu closes.
                ThemeChoice.saved = choice
                DispatchQueue.main.async { Theme.choose(choice) }
            }),
            toggle("Accent glow", "The open notch glows in the theme's accent color. Off: a plain dark shadow.",
                   get: { Settings.accentGlow }, set: { [unowned self] in
                       Settings.accentGlow = $0
                       host.panelsNeedRebuild()
                   }),
        ])
        section("Threads", [
            toggle("Show the model", "Each row says which model is running it.",
                   get: { Settings.showModel }, set: { [unowned self] in
                       Settings.showModel = $0
                       host.panelsNeedRebuild()
                   }),
        ])
    }
}

// MARK: - Views

/// An agent app has no main menu, so ⌘W / ⌘Q are handled here (only for this window: in the
/// notch's reply field they'd be typing, not quitting).
final class SettingsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods == .command else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers {
        case "w": performClose(nil); return true
        case "q": NSApp.terminate(nil); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }
}

/// Target for a control's action that runs a closure (controls hold their target weakly).
@MainActor
final class ActionTarget: NSObject {
    let body: () -> Void
    init(_ body: @escaping () -> Void) { self.body = body }
    @objc func fire() { body() }
}

/// Title (and an optional line under it) on the left, the control on the right.
@MainActor
final class Row: NSView {
    private let titleLabel: NSTextField
    private let detailLabel: NSTextField?
    private let keep: AnyObject?

    var dimmed = false {
        didSet {
            titleLabel.textColor = dimmed ? .tertiaryLabelColor : .labelColor
            detailLabel?.textColor = dimmed ? .quaternaryLabelColor : .secondaryLabelColor
        }
    }

    /// `reserve`: room the control takes on the right, so the detail wraps before reaching it.
    init(title: String, detail: String?, control: NSView, keep: AnyObject?, reserve: CGFloat, indent: Bool = false) {
        let leading: CGFloat = indent ? 30 : 12
        titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13)
        detailLabel = detail.map {
            let l = NSTextField(wrappingLabelWithString: $0)
            l.font = .systemFont(ofSize: 11)
            l.textColor = .secondaryLabelColor
            l.preferredMaxLayoutWidth = SettingsPane.width - 40 - leading - 12 - 12 - reserve
            return l
        }
        self.keep = keep
        super.init(frame: .zero)

        let text = NSStackView(views: [titleLabel] + (detailLabel.map { [$0] } ?? []))
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        [text, control].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leading),
            text.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
            control.leadingAnchor.constraint(greaterThanOrEqualTo: text.trailingAnchor, constant: 12),
            control.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            control.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 38),
            heightAnchor.constraint(greaterThanOrEqualTo: control.heightAnchor, constant: 12),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// The rounded, lightly filled group System Settings puts its rows in, with hairlines between rows.
@MainActor
final class GroupBox: NSView {
    private var separators: [NSBox] = []

    init(rows: [NSView]) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 0.5
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .width
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.detachesHiddenViews = true
        for (i, row) in rows.enumerated() {
            if i > 0 {
                let line = NSBox()
                line.boxType = .separator
                stack.addArrangedSubview(line)
                separators.append(line)
            }
            stack.addArrangedSubview(row)
        }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        // A hidden row takes its separator with it.
        for (i, row) in rows.enumerated() where i > 0 {
            let line = separators[i - 1]
            let observation = row.observe(\.isHidden, options: [.initial, .new]) { [weak line] row, _ in
                MainActor.assumeIsolated { line?.isHidden = row.isHidden }
            }
            observations.append(observation)
        }
    }

    private var observations: [NSKeyValueObservation] = []

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.quaternarySystemFill.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }
}
