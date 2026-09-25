import AppKit

/// The setup window: each permission Kosmos waits for, with a checkmark or a button to its
/// pane in System Settings, checked twice a second (DESIGN.md, section 5.9).
@MainActor
final class Onboarding {
    /// What the window shows.
    struct State: Equatable {
        var accessibility: Bool
        /// Nil while the window does not list Input Monitoring.
        var inputMonitoring: Bool? = nil

        var granted: Bool { accessibility && inputMonitoring != false }
    }

    private let window = SetupWindow()
    private var state: State
    /// Input Monitoring stays listed from the check that finds it missing until focus
    /// follows mouse turns off, so its grant shows as a checkmark.
    private var listsInputMonitoring: Bool
    private var timer: Timer?
    /// The close after the success state, until it runs.
    private var closing: DispatchWorkItem?
    /// Reads the permissions and acts on a grant. Input Monitoring is nil while focus follows
    /// mouse is off.
    private let check: @MainActor () -> State
    private let finished: @MainActor () -> Void

    /// `closedWithKey` runs as the window closes while it has the key, with whether that key
    /// came from another app.
    init(_ state: State, check: @escaping @MainActor () -> State,
         closedWithKey: @escaping @MainActor (_ fromAnotherApp: Bool) -> Void, finished: @escaping @MainActor () -> Void) {
        self.state = state
        listsInputMonitoring = state.inputMonitoring != nil
        self.check = check
        self.finished = finished
        window.closedWithKey = closedWithKey
        window.setContent(Self.content(for: state))
        window.center()
        startChecking()
    }

    /// Brings the window to the front of the normal level, and keeps it open if it was about
    /// to close. Only a launch lets Kosmos take the key: mid-session, a background accessory
    /// app does not become the front app (DESIGN.md, section 5.4).
    func show(takingKey: Bool) {
        if let closing {
            closing.cancel()
            self.closing = nil
            startChecking()
        }
        window.orderFrontRegardless()
        if takingKey { window.takeKey() }
    }

    private func startChecking() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        var next = check()
        listsInputMonitoring = next.inputMonitoring != nil && (listsInputMonitoring || next.inputMonitoring == false)
        if !listsInputMonitoring { next.inputMonitoring = nil }
        let granting = next.accessibility && !state.accessibility || next.inputMonitoring == true && state.inputMonitoring == false
        if next != state, next.granted, !granting {
            // The missing row left the list, as when focus follows mouse turns off: nothing was
            // granted, so the window closes without saying Kosmos is running.
            timer?.invalidate()
            window.close()
            return finished()
        }
        if next != state {
            state = next
            window.setContent(Self.content(for: state))
        }
        guard state.granted else { return }
        // Everything listed is granted: the window says Kosmos is running and closes 1.5 s later.
        timer?.invalidate()
        guard window.isVisible else { return finished() }
        let close = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.window.close()
                self?.finished()
            }
        }
        closing = close
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: close)
    }
}

// MARK: Content

extension Onboarding {
    private static let width: CGFloat = 480
    private static let margin: CGFloat = 24

    /// A permission the window lists.
    fileprivate enum Permission {
        case accessibility, inputMonitoring

        var name: String { self == .accessibility ? "Accessibility" : "Input Monitoring" }
        var reason: String { self == .accessibility ? "Required to move and resize your windows" : "Needed for focus follows mouse" }
        var symbol: String { self == .accessibility ? "accessibility" : "keyboard" }
        var color: NSColor { self == .accessibility ? .systemBlue : .systemGray }

        /// Opens its pane in System Settings, Privacy & Security.
        func openSettings() {
            if self == .accessibility {
                // Adds Kosmos to the Accessibility list so the user only has to switch it on.
                // The value of kAXTrustedCheckOptionPrompt, a global var that Swift 6 rejects.
                _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": false] as CFDictionary)
            }
            let pane = self == .accessibility ? "Privacy_Accessibility" : "Privacy_ListenEvent"
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
        }
    }

    /// The window's content at `state`, which `onboarding-snapshot` also draws.
    static func content(for state: State) -> NSView {
        let title = NSTextField(labelWithString: "Set up Kosmos")
        title.font = .systemFont(ofSize: 22, weight: .bold)
        let summary = NSTextField(wrappingLabelWithString: "Kosmos needs your permission to tile your windows.")
        summary.alignment = .center
        summary.textColor = .secondaryLabelColor
        summary.preferredMaxLayoutWidth = width - 2 * margin

        // The first button waiting for a grant takes Return.
        var rows = [row(.accessibility, granted: state.accessibility, takesReturn: !state.accessibility)]
        if let inputMonitoring = state.inputMonitoring {
            rows.append(row(.inputMonitoring, granted: inputMonitoring, takesReturn: state.accessibility && !inputMonitoring))
        }
        let list = NSStackView()
        list.orientation = .vertical
        list.spacing = 0
        for (index, row) in rows.enumerated() {
            if index > 0 { list.addArrangedSubview(separator()) }
            list.addArrangedSubview(row)
        }
        for view in list.arrangedSubviews { view.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true }
        let group = Drawing { bounds in
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
            NSColor.quinarySystemFill.setFill()
            path.fill()
            NSColor.separatorColor.setStroke()
            path.stroke()
        }
        group.addSubview(list)
        list.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: group.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: group.trailingAnchor),
            list.topAnchor.constraint(equalTo: group.topAnchor),
            list.bottomAnchor.constraint(equalTo: group.bottomAnchor),
        ])

        let mark = mark()
        let root = NSStackView(views: [mark, title, summary, group, footer(for: state)])
        root.orientation = .vertical
        root.alignment = .centerX
        root.spacing = 0
        root.setCustomSpacing(14, after: mark)
        root.setCustomSpacing(6, after: title)
        root.setCustomSpacing(20, after: summary)
        root.setCustomSpacing(16, after: group)
        // The top margin clears the transparent title bar.
        root.edgeInsets = NSEdgeInsets(top: 36, left: margin, bottom: 22, right: margin)
        root.widthAnchor.constraint(equalToConstant: width).isActive = true
        group.widthAnchor.constraint(equalToConstant: width - 2 * margin).isActive = true
        return root
    }

    /// Kosmos's mark until it has an app icon: three tiles, as the layout splits a display,
    /// on an indigo square.
    private static func mark() -> NSView {
        Drawing(size: NSSize(width: 64, height: 64)) { bounds in
            let square = bounds.insetBy(dx: 4, dy: 4)
            let path = NSBezierPath(roundedRect: square, xRadius: 12.5, yRadius: 12.5)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = .black.withAlphaComponent(0.3)
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.shadowBlurRadius = 2.5
            shadow.set()
            NSColor.black.setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSGradient(starting: NSColor(srgbRed: 0.47, green: 0.44, blue: 1, alpha: 1),
                       ending: NSColor(srgbRed: 0.27, green: 0.19, blue: 0.76, alpha: 1))?.draw(in: path, angle: -90)

            let inner = square.insetBy(dx: 11, dy: 11)
            let gap: CGFloat = 3
            let half = (inner.width - gap) / 2
            let tiles = [
                (NSRect(x: inner.minX, y: inner.minY, width: half, height: inner.height), 1.0),
                (NSRect(x: inner.maxX - half, y: inner.maxY - half, width: half, height: half), 0.8),
                (NSRect(x: inner.maxX - half, y: inner.minY, width: half, height: half), 0.62),
            ]
            for (tile, alpha) in tiles {
                NSColor.white.withAlphaComponent(alpha).setFill()
                NSBezierPath(roundedRect: tile, xRadius: 2.5, yRadius: 2.5).fill()
            }
        }
    }

    private static func row(_ permission: Permission, granted: Bool, takesReturn: Bool) -> NSView {
        let icon = Drawing(size: NSSize(width: 28, height: 28)) { bounds in
            permission.color.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6.5, yRadius: 6.5).fill()
            let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
            guard let image = NSImage(systemSymbolName: permission.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration) else { return }
            image.draw(in: NSRect(x: bounds.midX - image.size.width / 2, y: bounds.midY - image.size.height / 2,
                                  width: image.size.width, height: image.size.height))
        }
        let nameField = NSTextField(labelWithString: permission.name)
        nameField.font = .systemFont(ofSize: 13, weight: .medium)
        let reasonField = NSTextField(labelWithString: permission.reason)
        reasonField.font = .systemFont(ofSize: 11)
        reasonField.textColor = .secondaryLabelColor
        let text = NSStackView(views: [nameField, reasonField])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let status: NSView
        if granted {
            status = checkmark(pointSize: 18, description: "\(permission.name) allowed")
        } else {
            let button = SettingsButton(permission)
            button.setAccessibilityLabel("Open \(permission.name) Settings")
            if takesReturn { button.keyEquivalent = "\r" }
            status = button
        }
        status.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [icon, text, status])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        return row
    }

    private static func checkmark(pointSize: CGFloat, description: String?) -> NSImageView {
        let check = NSImageView(image: NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: description)!)
        check.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        check.contentTintColor = .systemGreen
        return check
    }

    /// A line between rows, from the text's edge, as System Settings draws its lists.
    private static func separator() -> NSView {
        Drawing(size: NSSize(width: NSView.noIntrinsicMetric, height: 1)) { bounds in
            NSColor.separatorColor.setFill()
            NSRect(x: 50, y: 0, width: bounds.width - 62, height: 1).fill()
        }
    }

    /// While waiting, what the grant does; once everything is granted, that Kosmos runs.
    private static func footer(for state: State) -> NSView {
        let symbol: NSView
        let text: NSTextField
        if state.granted {
            symbol = checkmark(pointSize: 14, description: nil)
            text = NSTextField(labelWithString: "Kosmos is running")
            text.font = .systemFont(ofSize: 13, weight: .medium)
        } else {
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.startAnimation(nil)
            symbol = spinner
            text = NSTextField(labelWithString: state.accessibility
                ? "Focus follows mouse starts once Input Monitoring is on"
                : "Kosmos starts on its own once Accessibility is on")
            text.font = .systemFont(ofSize: 12)
            text.textColor = .secondaryLabelColor
        }
        let footer = NSStackView(views: [symbol, text])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 6
        return footer
    }
}

// MARK: Snapshot

extension Onboarding {
    /// `Kosmos onboarding-snapshot <directory>`: draws the window in each state, in light and
    /// dark mode, into PNG files in the directory. The window is never shown.
    static func snapshot(_ arguments: [String]) -> Int32 {
        guard arguments.count == 1 else {
            FileHandle.standardError.write(Data("usage: Kosmos onboarding-snapshot <directory>\n".utf8))
            return 2
        }
        let directory = URL(filePath: arguments[0], directoryHint: .isDirectory)
        let states: [(String, State)] = [
            ("waiting", State(accessibility: false)),
            ("input-monitoring", State(accessibility: true, inputMonitoring: false)),
            ("running", State(accessibility: true, inputMonitoring: true)),
        ]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (name, state) in states {
                for (appearance, mode) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                    let window = SetupWindow()
                    window.appearance = NSAppearance(named: appearance)
                    window.setContent(content(for: state))
                    // The frame view, so the picture has the title bar's close button.
                    let view = window.contentView!.superview!
                    let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    let file = directory.appending(path: "\(name)-\(mode).png")
                    try bitmap.representation(using: .png, properties: [:])!.write(to: file)
                    print(file.path)
                }
            }
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            return 1
        }
        return 0
    }
}

/// Draws with a closure. AppKit sets the view's appearance as current while it draws, so
/// the closure's colors follow light and dark mode.
private final class Drawing: NSView {
    private let size: NSSize
    private let drawing: @MainActor (NSRect) -> Void

    init(size: NSSize = NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric),
         _ drawing: @escaping @MainActor (NSRect) -> Void) {
        self.size = size
        self.drawing = drawing
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize { size }

    override func draw(_ dirtyRect: NSRect) { drawing(bounds) }
}

/// Opens its permission's pane in System Settings.
private final class SettingsButton: NSButton {
    private var permission = Onboarding.Permission.accessibility

    fileprivate convenience init(_ permission: Onboarding.Permission) {
        self.init(title: "Open Settings", target: nil, action: nil)
        self.permission = permission
        target = self
        action = #selector(open)
    }

    /// While Kosmos is in the background, as it is mid-session, a click on the button presses
    /// it and does not only bring the window forward.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func open() { permission.openSettings() }
}

/// A window at the normal level whose title bar shows only the close button. Escape and
/// Command-W close it, since Kosmos has no main menu to carry Close.
private final class SetupWindow: NSWindow {
    /// Runs as the window closes while it has the key, with whether that key came from
    /// another app: Kosmos was not active before the window took it.
    var closedWithKey: (@MainActor (_ fromAnotherApp: Bool) -> Void)?
    private var tookKeyFromAnotherApp = false
    /// Kosmos is becoming active, until one of its windows takes the key.
    private var activating = false

    init() {
        super.init(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView],
                   backing: .buffered, defer: true)
        title = "Set up Kosmos"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(appWillBecomeActive), name: NSApplication.willBecomeActiveNotification,
                           object: nil)
        center.addObserver(self, selector: #selector(windowBecameKey), name: NSWindow.didBecomeKeyNotification, object: nil)
    }

    /// Activates Kosmos and takes the key, which only a launch can do, from the app that was
    /// active before.
    func takeKey() {
        activating = true
        NSApp.activate()
        makeKey()
    }

    @objc private func appWillBecomeActive() { activating = true }

    @objc private func windowBecameKey(_ notification: Notification) {
        if notification.object as? NSWindow === self { tookKeyFromAnotherApp = activating }
        activating = false
    }

    override func close() {
        if isKeyWindow { closedWithKey?(tookKeyFromAnotherApp) }
        super.close()
    }

    /// Replaces the content and fits the window to it, keeping its top edge.
    func setContent(_ view: NSView) {
        let top = frame.maxY
        contentView = view
        var fitted = frameRect(forContentRect: NSRect(origin: .zero, size: view.fittingSize))
        fitted.origin = NSPoint(x: frame.minX, y: top - fitted.height)
        setFrame(fitted, display: true, animate: isVisible)
        recalculateKeyViewLoop()
    }

    override func cancelOperation(_ sender: Any?) { close() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              event.charactersIgnoringModifiers == "w" else { return super.performKeyEquivalent(with: event) }
        close()
        return true
    }
}
