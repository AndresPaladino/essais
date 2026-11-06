import AppKit

/// Letra y tamaño: the notebook's only settings, both for legibility. NSPopover is glass on macOS 26.
@MainActor
final class ReadingPopover: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        super.init()
        popover.behavior = .transient
        popover.delegate = self
    }

    /// See IndexPopover: its own button closes it instantly, never as "a click outside".
    private weak var anchor: NSToolbarItem?
    private var closing = false
    func popoverShouldClose(_ popover: NSPopover) -> Bool { !clickIsOn(anchor, NSApp.currentEvent) }
    func popoverWillClose(_ notification: Notification) { closing = true }
    func popoverDidClose(_ notification: Notification) { closing = false }

    var isShown: Bool { popover.isShown && !closing }

    func closeNow() {
        popover.animates = false
        popover.close()
        popover.animates = true
    }

    func toggle(from item: NSToolbarItem) {
        // Same as the index: closing is immediate, so a quick second press always does something.
        anchor = item
        if popover.isShown, !closing { closeNow(); return }
        popover.contentViewController = content()
        popover.show(relativeTo: item)
    }

    private func content() -> NSViewController {
        let smaller = NSButton(title: "", target: self, action: #selector(smaller))
        smaller.attributedTitle = NSAttributedString(string: "A", attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)])
        let bigger = NSButton(title: "", target: self, action: #selector(bigger))
        bigger.attributedTitle = NSAttributedString(string: "A", attributes: [.font: NSFont.systemFont(ofSize: 20, weight: .medium)])
        for b in [smaller, bigger] { b.bezelStyle = .glass; b.controlSize = .large }
        smaller.setAccessibilityLabel(String(localized: "Smaller Text"))
        bigger.setAccessibilityLabel(String(localized: "Bigger Text"))
        let sizes = NSStackView(views: [smaller, bigger])
        sizes.distribution = .fillEqually

        var rows: [NSView] = [sizes]
        for font in Fonts.allCases {
            let b = NSButton(radioButtonWithTitle: font.title, target: self, action: #selector(pick(_:)))
            b.attributedTitle = NSAttributedString(string: font.title, attributes: [.font: font.font(15)])
            b.identifier = NSUserInterfaceItemIdentifier(font.rawValue)
            b.state = Reading.font == font ? .on : .off
            rows.append(b)
        }
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        sizes.translatesAutoresizingMaskIntoConstraints = false
        sizes.widthAnchor.constraint(equalToConstant: 220).isActive = true
        self.smallerButton = smaller
        self.biggerButton = bigger
        updateLimits()
        let controller = NSViewController()
        controller.view = stack
        // Measured as laid out: fittingSize alone left out the side margins and the right button touched the edge.
        stack.layoutSubtreeIfNeeded()
        controller.preferredContentSize = NSSize(width: 220 + 32, height: stack.fittingSize.height)
        return controller
    }

    private weak var smallerButton: NSButton?
    private weak var biggerButton: NSButton?
    private func updateLimits() {
        smallerButton?.isEnabled = Reading.size > Reading.sizes.lowerBound
        biggerButton?.isEnabled = Reading.size < Reading.sizes.upperBound
    }

    @objc private func smaller() { Reading.size -= 1; updateLimits(); onChange(); announce() }
    @objc private func bigger() { Reading.size += 1; updateLimits(); onChange(); announce() }
    private func announce() {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: Reading.sizeAnnouncement, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
    @objc private func pick(_ sender: NSButton) {
        if let raw = sender.identifier?.rawValue, let font = Fonts(rawValue: raw) { Reading.font = font; onChange() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = NotebookStore()
    private var notebook: NotebookController!
    #if QA
    private var probe: DispatchSourceSignal?
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        carryOverSettings()
        NSApp.mainMenu = menu()
        guard bringJournal() else { NSApp.terminate(nil); return }
        notebook = NotebookController(store: store)
        notebook.showWindow(nil)
        notebook.load()
        notebook.openAtEnd()
        notebook.startWatching()
        #if QA
        // ESSAIS_QUIET: a test instance that doesn't take the front from whoever is working.
        if QA.env("ESSAIS_QUIET") == nil { NSApp.activate() }

        // Test hooks: ESSAIS_DEBUG=1 Essais [--type text] [--zoom 0.5] [--snapshot png] [--delay s]
        guard QA.env("ESSAIS_DEBUG") == "1" else { return }
        let args = CommandLine.arguments
        if args.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        signal(SIGUSR1, SIG_IGN)
        let probe = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        probe.setEventHandler { [self] in FileHandle.standardError.write((notebook.debugTail() + "\n").data(using: .utf8)!) }
        probe.resume()
        self.probe = probe
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [self] in
            if let text = value("--type") { notebook.type(text) }
            if let zoom = value("--zoom").flatMap(Double.init) { notebook.magnify(CGFloat(zoom)) }
            if args.contains("--index") { notebook.showIndex(nil) }
            if args.contains("--search") { notebook.showSearch(nil) }
            if let keys = value("--index-keys") {
                notebook.showIndex(nil)
                let codes = keys.split(separator: ",").compactMap { UInt16($0) }
                DispatchQueue.main.async { [self] in
                    FileHandle.standardError.write((notebook.debugIndexKeys(codes) + "\n").data(using: .utf8)!)
                }
            }
            if let i = args.firstIndex(of: "--type-at"), i + 2 < args.count {
                FileHandle.standardError.write((notebook.debugTypeAt(args[i + 1], args[i + 2]) + "\n").data(using: .utf8)!)
            }
            if let d = value("--delete-after") { FileHandle.standardError.write((notebook.debugDeleteAfter(d) + "\n").data(using: .utf8)!) }
            if let k = value("--keys") { FileHandle.standardError.write((notebook.debugKeys(k) + "\n").data(using: .utf8)!) }
            if let c = value("--click") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [self] in
                    FileHandle.standardError.write((notebook.debugClicks(c) + "\n").data(using: .utf8)!)
                }
            }
            if let c = value("--cross") { FileHandle.standardError.write((notebook.debugCross(c) + "\n").data(using: .utf8)!) }
            if let c = value("--drop") { FileHandle.standardError.write((notebook.debugDrop(c) + "\n").data(using: .utf8)!) }
            if args.contains("--menu") { FileHandle.standardError.write((notebook.debugMenu() + "\n").data(using: .utf8)!) }
            if let z = value("--zoom-probe").flatMap(Double.init) { FileHandle.standardError.write((notebook.debugZoom(CGFloat(z)) + "\n").data(using: .utf8)!) }
            if args.contains("--cursor-check") { FileHandle.standardError.write((notebook.debugCursors() + "\n").data(using: .utf8)!) }
            if args.contains("--rotors") { FileHandle.standardError.write((notebook.debugRotors() + "\n").data(using: .utf8)!) }
            if args.contains("--scroll-log") { notebook.debugScrollLog() }
            if let text = value("--find") { notebook.find(text) }
            if let mode = value("--size-walk") { notebook.debugSizeWalk(mode) }
            if args.contains("--about") { showAbout(nil) }
            if args.contains("--camera-bench") { notebook.debugCameraBench() }
            if let m = value("--soak").flatMap(Double.init) { notebook.debugSoak(minutes: m) }
            if let z = value("--enter-probe").flatMap(Double.init) { notebook.debugEnterProbe(CGFloat(z)) }
            // --update-test s: fetch the local feed (ESSAIS_FEED), then quit after s seconds, which installs.
            if let wait = value("--update-test").flatMap(Double.init) {
                Updater.shared.start()
                Updater.shared.installInBackground()
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) { NSApp.terminate(nil) }
            }
            if let pause = value("--day-pause").flatMap(Double.init) { notebook.newDayPause = pause }
            // --midnight s: in s seconds it's tomorrow, as far as Essais can tell.
            if let delay = value("--midnight").flatMap(Double.init) {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
                    notebook.debugToday = NotebookStore.key(Date().addingTimeInterval(24 * 3600))
                    NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)
                }
            }
            if args.contains("--show-title") { notebook.showFirstTitle() }
            if let path = value("--snapshot") {
                let delay = value("--delay").flatMap(Double.init) ?? 1
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
                    notebook.snapshot(to: path)
                    notebook.saveNow()
                    NSApp.terminate(nil)
                }
            }
        }
        #else
        NSApp.activate()
        Updater.shared.start()
        #endif
    }

    /// The standard panel: icon, name, version and copyright (from Info.plist), and one line about it.
    @objc func showAbout(_ sender: Any?) {
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        let credits = NSAttributedString(string: String(localized: "One notebook to write in, day after day."), attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: center,
        ])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate()
    }

    /// Letter, size and window frame chosen while the app was the "Cuaderno" prototype.
    private func carryOverSettings() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "carriedOver"), let old = UserDefaults(suiteName: "com.andrespaladino.cuaderno.prototipo") else { return }
        for key in ["font", "size", "NSWindow Frame Notebook"] where defaults.object(forKey: key) == nil {
            if let value = old.object(forKey: key) { defaults.set(value, forKey: key) }
        }
        defaults.set(true, forKey: "carriedOver")
    }

    /// The first time, the ClearMind journal comes into the notebook. If that fails nothing has
    /// been written yet, so the app says so and quits rather than start an empty notebook.
    private func bringJournal() -> Bool {
        guard Migration.needed(into: store) else { return true }
        do {
            let report = try Migration.run(into: store)
            Migration.markDone(in: store)
            let summary = "Essais: \(report.entries) entradas → \(report.days) días (\(report.skippedEmpty) vacías), copia en \(report.backup?.path ?? "-"), letras \(report.ok ? "iguales" : "DISTINTAS")"
            NSLog("%@", summary)
            for c in report.check where c.before != c.after { NSLog("Essais: %@ %d → %d", c.day, c.before, c.after) }
            // The one time the app moves your journal: if the check fails, it says so and where the copy is.
            if !report.ok {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = String(localized: "Some days of the ClearMind journal came in different")
                alert.informativeText = String(localized: "Nothing was deleted: the ClearMind journal is still in its place, and there’s a copy in the backup folder.")
                alert.addButton(withTitle: String(localized: "OK"))
                alert.addButton(withTitle: String(localized: "Show in Finder"))
                if alert.runModal() == .alertSecondButtonReturn, let backup = report.backup { NSWorkspace.shared.activateFileViewerSelecting([backup]) }
            }
            return true
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = String(localized: "The ClearMind journal couldn’t be brought in")
            alert.informativeText = String(localized: "Nothing was changed. \(error.localizedDescription)")
            alert.runModal()
            return false
        }
    }

    /// ⌘W closes the window and Essais stays, as Notes does; the Dock icon brings the notebook back.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { notebook?.showWindow(nil); notebook?.window?.makeKeyAndOrderFront(nil) }
        return true
    }
    func applicationWillTerminate(_ notification: Notification) { notebook?.saveNow(everything: true) }

    /// Quitting while some writing couldn't be saved would lose it: ask first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let notebook, let failed = notebook.saveNow(everything: true).failed.first else { return .terminateNow }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = String(localized: "The writing of \(NotebookIndex.longDate(failed.day)) couldn’t be saved")
        alert.informativeText = String(localized: "If you quit now, what wasn’t saved will be lost. You can copy it first.")
        alert.addButton(withTitle: String(localized: "Don’t Quit"))
        alert.addButton(withTitle: String(localized: "Quit Anyway"))
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    // The Edit submenus every Mac text app has, wired to NSTextView's own actions.
    private func spellingMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(withTitle: String(localized: "Show Spelling and Grammar"), action: #selector(NSText.showGuessPanel(_:)), keyEquivalent: ":")
        m.addItem(withTitle: String(localized: "Check Document Now"), action: #selector(NSText.checkSpelling(_:)), keyEquivalent: ";")
        m.addItem(.separator())
        m.addItem(withTitle: String(localized: "Check Spelling While Typing"), action: #selector(NSTextView.toggleContinuousSpellChecking(_:)), keyEquivalent: "")
        m.addItem(withTitle: String(localized: "Check Grammar With Spelling"), action: #selector(NSTextView.toggleGrammarChecking(_:)), keyEquivalent: "")
        m.addItem(withTitle: String(localized: "Correct Spelling Automatically"), action: #selector(NSTextView.toggleAutomaticSpellingCorrection(_:)), keyEquivalent: "")
        return m
    }

    private func substitutionsMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(withTitle: String(localized: "Show Substitutions"), action: #selector(NSTextView.orderFrontSubstitutionsPanel(_:)), keyEquivalent: "")
        m.addItem(.separator())
        m.addItem(withTitle: String(localized: "Smart Copy/Paste"), action: #selector(NSTextView.toggleSmartInsertDelete(_:)), keyEquivalent: "")
        m.addItem(withTitle: String(localized: "Smart Quotes"), action: #selector(NSTextView.toggleAutomaticQuoteSubstitution(_:)), keyEquivalent: "")
        m.addItem(withTitle: String(localized: "Smart Dashes"), action: #selector(NSTextView.toggleAutomaticDashSubstitution(_:)), keyEquivalent: "")
        m.addItem(withTitle: String(localized: "Text Replacement"), action: #selector(NSTextView.toggleAutomaticTextReplacement(_:)), keyEquivalent: "")
        return m
    }

    private func transformationsMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(withTitle: String(localized: "Make Upper Case"), action: #selector(NSResponder.uppercaseWord(_:)), keyEquivalent: "")
        m.addItem(withTitle: String(localized: "Make Lower Case"), action: #selector(NSResponder.lowercaseWord(_:)), keyEquivalent: "")
        m.addItem(withTitle: String(localized: "Capitalize"), action: #selector(NSResponder.capitalizeWord(_:)), keyEquivalent: "")
        return m
    }

    private func speechMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(withTitle: String(localized: "Start Speaking"), action: #selector(NSTextView.startSpeaking(_:)), keyEquivalent: "")
        m.addItem(withTitle: String(localized: "Stop Speaking"), action: #selector(NSTextView.stopSpeaking(_:)), keyEquivalent: "")
        return m
    }

    private func menu() -> NSMenu {
        let main = NSMenu()
        func sub(_ title: String) -> NSMenu {
            let m = NSMenu(title: title)
            main.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = m
            return m
        }
        let app = sub("Essais")
        app.addItem(withTitle: String(localized: "About Essais"), action: #selector(showAbout(_:)), keyEquivalent: "").target = self
        app.addItem(withTitle: String(localized: "Check for Updates…"), action: #selector(Updater.checkForUpdates(_:)), keyEquivalent: "").target = Updater.shared
        app.addItem(.separator())
        app.addItem(withTitle: String(localized: "Hide Essais"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: String(localized: "Hide Others"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: String(localized: "Show All"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: String(localized: "Quit Essais"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = sub(String(localized: "File"))
        file.addItem(withTitle: String(localized: "Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let edit = sub(String(localized: "Edit"))
        edit.addItem(withTitle: String(localized: "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        // Shifted shortcuts are declared with the capital letter, as AppKit compares it with what the key types.
        edit.addItem(withTitle: String(localized: "Redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: String(localized: "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: String(localized: "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: String(localized: "Paste and Match Style"), action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "V")
            .keyEquivalentModifierMask = [.command, .option]
        edit.addItem(withTitle: String(localized: "Delete"), action: #selector(NSText.delete(_:)), keyEquivalent: "")
        edit.addItem(withTitle: String(localized: "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: String(localized: "Spelling and Grammar"), action: nil, keyEquivalent: "").submenu = spellingMenu()
        edit.addItem(withTitle: String(localized: "Substitutions"), action: nil, keyEquivalent: "").submenu = substitutionsMenu()
        edit.addItem(withTitle: String(localized: "Transformations"), action: nil, keyEquivalent: "").submenu = transformationsMenu()
        edit.addItem(withTitle: String(localized: "Speech"), action: nil, keyEquivalent: "").submenu = speechMenu()
        edit.addItem(.separator())
        let find = NSMenu(title: String(localized: "Find"))
        edit.addItem(withTitle: String(localized: "Find"), action: nil, keyEquivalent: "").submenu = find
        find.addItem(withTitle: String(localized: "Find…"), action: #selector(NotebookController.showSearch(_:)), keyEquivalent: "f")
        find.addItem(withTitle: String(localized: "Find Next"), action: #selector(NotebookController.findNext(_:)), keyEquivalent: "g")
        find.addItem(withTitle: String(localized: "Find Previous"), action: #selector(NotebookController.findPrevious(_:)), keyEquivalent: "G")
        find.addItem(withTitle: String(localized: "Use Selection for Find"), action: #selector(NotebookController.useSelectionForFind(_:)), keyEquivalent: "e")

        let view = sub(String(localized: "View"))
        view.addItem(withTitle: String(localized: "Index"), action: #selector(NotebookController.showIndex(_:)), keyEquivalent: "I")
        view.addItem(withTitle: String(localized: "Go to Date…"), action: #selector(NotebookController.goToDate(_:)), keyEquivalent: "T")
        view.addItem(withTitle: String(localized: "Jump to Selection"), action: #selector(NSResponder.centerSelectionInVisibleArea(_:)), keyEquivalent: "j")
        view.addItem(.separator())
        let fonts = NSMenu()
        for font in Fonts.allCases {
            fonts.addItem(withTitle: font.title, action: #selector(NotebookController.pickFont(_:)), keyEquivalent: "").representedObject = font.rawValue
        }
        view.addItem(withTitle: String(localized: "Font"), action: nil, keyEquivalent: "").submenu = fonts
        // ⌘+ / ⌘− change the text size, as in TextEdit; pinching on the trackpad moves the camera, like Safari.
        view.addItem(withTitle: String(localized: "Bigger"), action: #selector(NotebookController.bigger(_:)), keyEquivalent: "+")
        view.addItem(withTitle: String(localized: "Smaller"), action: #selector(NotebookController.smaller(_:)), keyEquivalent: "-")
        view.addItem(withTitle: String(localized: "Reset Zoom"), action: #selector(NotebookController.actualSize(_:)), keyEquivalent: "0")
        view.addItem(.separator())
        view.addItem(withTitle: String(localized: "Enter Full Screen"), action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f").keyEquivalentModifierMask = [.command, .control]

        let format = sub(String(localized: "Format"))
        format.addItem(withTitle: String(localized: "Bold"), action: #selector(NotebookController.bold(_:)), keyEquivalent: "b")
        format.addItem(withTitle: String(localized: "Italic"), action: #selector(NotebookController.italic(_:)), keyEquivalent: "i")
        format.addItem(.separator())
        for (level, title) in [String(localized: "Title"), String(localized: "Heading"), String(localized: "Subheading")].enumerated() {
            format.addItem(withTitle: title, action: #selector(NotebookController.heading(_:)), keyEquivalent: String(level + 1)).tag = level + 1
        }

        let window = sub(String(localized: "Window"))
        window.addItem(withTitle: String(localized: "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: String(localized: "Zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: String(localized: "Bring All to Front"), action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window

        // Help: macOS puts its menu search here.
        NSApp.helpMenu = sub(String(localized: "Help"))
        return main
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    NSWindow.allowsAutomaticWindowTabbing = false
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    withExtendedLifetime(delegate) { app.run() }
}
