import AppKit

/// The paper: white, edge to edge, with a column of text of fixed width, like a PDF page.
/// The column never re-wraps when the window changes; pinching moves the camera closer or
/// farther (NSScrollView magnification), like Preview. Only Aa changes the type itself.
final class PaperTextView: NSTextView {
    /// The measure of the column, in em: the same ~70 characters a line at any size (640 pt at 17).
    static let measure: CGFloat = 640.0 / 17
    /// In windows narrower than the column, the column narrows (and re-wraps) keeping this margin.
    static let narrowMargin: CGFloat = 36

    /// The column for a given paper width: its measure, or less when the window is narrower.
    static func columnWidth(for width: CGFloat) -> CGFloat {
        min(measure * Reading.size, max(200, width - narrowMargin * 2)).rounded()
    }
    /// Window areas where the controls float over the paper (toolbar, search capsule). The text
    /// view runs under them, so without this the I-beam showed over the buttons.
    var controlAreas: (() -> [NSRect])?
    var onSmartMagnify: ((NSEvent) -> Void)?

    /// Two-finger double tap, like Safari: closer, then back.
    override func smartMagnify(with event: NSEvent) {
        if let onSmartMagnify { onSmartMagnify(event) } else { super.smartMagnify(with: event) }
    }

    static let top: CGFloat = 96
    /// Paper below the last line, so it can rise to the writing line. It is part of the text view,
    /// not an inset of the scroll view: a click there puts the caret at the end, as in TextEdit.
    var bottomRoom: CGFloat = 0 { didSet { if bottomRoom != oldValue { updateInset() } } }

    /// The paper is as wide as the window, whatever the zoom: set by the controller from the clip
    /// view's frame. NSTextView on its own follows the clip's *bounds*, which halve at 2× — the
    /// column then re-wrapped mid-pinch and the camera slid sideways.
    var paperWidth: CGFloat = 0

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(NSSize(width: paperWidth > 0 ? paperWidth : newSize.width, height: newSize.height))
        updateInset()
    }

    /// The inset is symmetric, so the container is pinned to `top` and the rest of the height goes
    /// below the text.
    func updateInset() {
        // Not rounded: the column is exactly its width whatever the window's (639/640 re-wrapped everything).
        let inset = NSSize(width: (frame.width - Self.columnWidth(for: frame.width)) / 2, height: ((Self.top + bottomRoom) / 2).rounded())
        if textContainerInset != inset { textContainerInset = inset }
    }

    override var textContainerOrigin: NSPoint { NSPoint(x: super.textContainerOrigin.x, y: Self.top) }

    /// Every time AppKit wants to show a range (typing, arrows, selection), the controller decides:
    /// writing at the end keeps the line on the writing line; anywhere else the paper moves only
    /// as much as needed to keep the range in view, clear of the toolbar.
    override func scrollRangeToVisible(_ range: NSRange) {
        if suppressFollow { return }
        // When text re-wraps the layout manager asks to keep what was on screen, with a long range that
        // isn't the selection. The place is kept by the anchors; following this sent the paper elsewhere.
        if range.length > 0, range != selectedRange() { return }
        if let onShow { onShow(range) } else { super.scrollRangeToVisible(range) }
    }
    var onShow: ((NSRange) -> Void)?

    /// Page Up/Down are the controller's: what turns the page is a line, not a distance.
    var onPage: ((Int) -> Void)?
    override func scrollPageUp(_ sender: Any?) { onPage?(-1) }
    override func scrollPageDown(_ sender: Any?) { onPage?(1) }

    /// Called when the text takes the keyboard back (from search, the index, a popover).
    var onBecomeFirstResponder: (() -> Void)?
    private var suppressFollow = false

    /// Coming back to the text with a click: AppKit first scrolls to the old selection, so the
    /// paper jumped before the click landed. The click itself says where the caret goes.
    override func becomeFirstResponder() -> Bool {
        let byClick = NSApp.currentEvent?.type == .leftMouseDown
        suppressFollow = byClick
        let ok = super.becomeFirstResponder()
        suppressFollow = false
        if ok { onBecomeFirstResponder?() }
        return ok
    }

    /// The text view's own menu, without what doesn't apply to a notebook (vertical layout).
    /// ⌘A selects the day you're writing in, as Notes selects the note; ⌘A again, the whole notebook
    /// (to copy it). Wiping years of writing takes a deliberate second press.
    private var selectedDay: NSRange?
    override func selectAll(_ sender: Any?) {
        if let day = selectedDay, selectedRange() == day {
            selectedDay = nil
            super.selectAll(sender)
            return
        }
        guard let day = dayBody(at: selectedRange().location) else { super.selectAll(sender); return }
        selectedDay = day
        breakUndoCoalescing()
        setSelectedRange(day)
    }

    /// The writing of the day at `location`: after its date line, before the break that ends it.
    func dayBody(at location: Int) -> NSRange? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        let index = min(max(0, location > 0 ? location - 1 : 0), storage.length - 1)
        var run = NSRange()
        guard storage.attribute(.day, at: index, longestEffectiveRange: &run, in: NSRange(location: 0, length: storage.length)) != nil else { return nil }
        var start = run.location, end = NSMaxRange(run)
        var line = NSRange()
        if storage.attribute(.dateLine, at: start, longestEffectiveRange: &line, in: run) != nil { start = NSMaxRange(line) }
        if end < storage.length, end > start, (storage.string as NSString).character(at: end - 1) == 0x0A { end -= 1 }
        return NSRange(location: start, length: max(0, end - start))
    }

    /// The day file for a day key (set by the controller), for "Show in Finder".
    var fileForDay: ((String) -> URL)?

    @objc private func showDayInFinder(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// A right click on the band is a right click on the title bar: nothing, and never a word
    /// hidden under it selected, ready to be typed over.
    override func rightMouseDown(with event: NSEvent) {
        if isTitleBar?(event) == true { return }
        super.rightMouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        if isTitleBar?(event) == true { return nil }
        guard let menu = super.menu(for: event) else { return nil }
        // Show in Finder: the file of the day you clicked on (or the folder, if it hasn't been saved yet).
        let at = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        if let storage = textStorage, storage.length > 0, let fileForDay,
           let key = storage.attribute(.day, at: min(max(0, at), storage.length - 1), effectiveRange: nil) as? String {
            let file = fileForDay(key)
            let target = FileManager.default.fileExists(atPath: file.path) ? file : file.deletingLastPathComponent()
            menu.addItem(.separator())
            let item = menu.addItem(withTitle: String(localized: "Show in Finder"), action: #selector(showDayInFinder(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = target
        }
        let unwanted: Set<Selector> = [#selector(NSTextView.changeLayoutOrientation(_:)), #selector(NSFontManager.orderFrontFontPanel(_:))]
        for item in menu.items.reversed() {
            let actions = [item.action] + (item.submenu?.items.map(\.action) ?? [])
            if actions.contains(where: { $0.map(unwanted.contains) ?? false }) { menu.removeItem(item) }
        }
        // No separators left back to back.
        for (i, item) in menu.items.enumerated().reversed() where item.isSeparatorItem {
            if i == 0 || i == menu.items.count - 1 || menu.items[i - 1].isSeparatorItem { menu.removeItem(item) }
        }
        return menu
    }

    /// The paper always starts at the top of the scroll view. Created with no superview, TextKit 1
    /// grows the view downwards from its first (unflipped) frame and leaves it hundreds of points
    /// above the clip: the window opened on blank paper.
    override func setFrameOrigin(_ newOrigin: NSPoint) { super.setFrameOrigin(.zero) }

    var rotors: NotebookRotors?
    override func accessibilityCustomRotors() -> [NSAccessibilityCustomRotor] { rotors?.rotors ?? [] }

    /// Only for VoiceOver: other tools that read the text (Voice Control, Writing Tools) need the real one.
    private var voiceOverIsReading: Bool {
        #if QA
        if QA.env("ESSAIS_VO") == "1" { return true }
        #endif
        return NSWorkspace.shared.isVoiceOverEnabled
    }

    /// Lines and words are read without their marks. One character at a time they are read as they
    /// are: that's how you find out what's there when correcting.
    private func spoken(_ text: NSAttributedString?, _ range: NSRange) -> NSAttributedString? {
        guard let text, range.length > 1, voiceOverIsReading, let textStorage else { return text }
        return Markdown.withoutMarks(text, in: range, of: textStorage)
    }

    override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        spoken(super.accessibilityAttributedString(for: range), range)
    }

    override func accessibilityString(for range: NSRange) -> String? {
        guard let text = super.accessibilityString(for: range) else { return nil }
        return spoken(NSAttributedString(string: text), range)?.string ?? text
    }

    private func overControls(_ event: NSEvent) -> Bool {
        controlAreas?().contains { $0.contains(event.locationInWindow) } ?? false
    }

    /// The band under the toolbar behaves as the title bar it looks like: drag moves the window,
    /// a double click does what the system setting says (zoom, minimize or nothing).
    var isTitleBar: ((NSEvent) -> Bool)?

    override func mouseDown(with event: NSEvent) {
        guard isTitleBar?(event) == true, let window else { return super.mouseDown(with: event) }
        if event.clickCount == 2 {
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize": window.performMiniaturize(nil)
            case "None": break
            default: window.performZoom(nil)
            }
        } else {
            window.performDrag(with: event)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        if overControls(event) { NSCursor.arrow.set(); return }
        super.mouseMoved(with: event)
    }

    override func cursorUpdate(with event: NSEvent) {
        if overControls(event) { NSCursor.arrow.set(); return }
        super.cursorUpdate(with: event)
    }

    override func paste(_ sender: Any?) { pasteAsPlainText(sender) }

    /// Unicode line separators are invisible here and strange in any other editor: lines are lines.
    override func pasteAsPlainText(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string), text.contains(where: { $0 == "\u{2028}" || $0 == "\u{2029}" }) else {
            return super.pasteAsPlainText(sender)
        }
        breakUndoCoalescing()
        insertText(text.replacingOccurrences(of: "\u{2028}", with: "\n").replacingOccurrences(of: "\u{2029}", with: "\n"), replacementRange: selectedRange())
        breakUndoCoalescing()
    }

    /// ⌃↩ in other apps: a soft break. Here, plain files: a line is a line.
    override func insertLineBreak(_ sender: Any?) { insertNewline(sender) }

    /// A dead key or an input method over a selection: the selection has to be cleared first (across
    /// days, only its writing goes) so the composition is marked in the place that remains.
    var clearSelectionForComposing: (() -> Void)?

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        clearSelectionForComposing?()
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }

    /// Empty lines are set small so a blank line between paragraphs doesn't double the gap; the
    /// caret there would be a few points tall. It is always drawn at the height of the text.
    private var caretHeight: CGFloat {
        let font = Reading.body
        return (font.ascender - font.descender + font.leading).rounded()
    }

    private func fullCaret(_ rect: NSRect) -> NSRect {
        guard rect.height < caretHeight else { return rect }
        var r = rect
        r.size.height = caretHeight
        r.origin.y = (rect.midY - caretHeight / 2).rounded()
        return r
    }

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        super.drawInsertionPoint(in: fullCaret(rect), color: color, turnedOn: flag)
    }

    /// The taller caret has to be erased too: what AppKit invalidates for it grows the same way.
    override func setNeedsDisplay(_ invalidRect: NSRect, avoidAdditionalLayout flag: Bool) {
        var r = invalidRect
        if r.width <= 4, r.height < caretHeight { r = fullCaret(r).insetBy(dx: -1, dy: -1) }
        super.setNeedsDisplay(r, avoidAdditionalLayout: flag)
    }

    // Spelling choices are remembered, as in Notes and TextEdit. Checking while typing is on by default.
    func restoreSpelling() {
        let d = UserDefaults.standard
        isContinuousSpellCheckingEnabled = d.object(forKey: "spelling") as? Bool ?? true
        isGrammarCheckingEnabled = d.bool(forKey: "grammar")
        if let auto = d.object(forKey: "autocorrect") as? Bool { isAutomaticSpellingCorrectionEnabled = auto }
    }
    override func toggleContinuousSpellChecking(_ sender: Any?) {
        super.toggleContinuousSpellChecking(sender); UserDefaults.standard.set(isContinuousSpellCheckingEnabled, forKey: "spelling")
    }
    override func toggleGrammarChecking(_ sender: Any?) {
        super.toggleGrammarChecking(sender); UserDefaults.standard.set(isGrammarCheckingEnabled, forKey: "grammar")
    }
    override func toggleAutomaticSpellingCorrection(_ sender: Any?) {
        super.toggleAutomaticSpellingCorrection(sender); UserDefaults.standard.set(isAutomaticSpellingCorrectionEnabled, forKey: "autocorrect")
    }
}

@MainActor
final class NotebookController: NSWindowController, NSWindowDelegate, NSTextViewDelegate,
    @preconcurrency NSTextStorageDelegate, NSToolbarDelegate, NSMenuItemValidation {

    private let store: NotebookStore
    private let scrollView = NSScrollView()
    private lazy var camera = PaperCamera(scrollView: scrollView)
    /// TextKit 1: it draws whatever the magnified clip view shows. TextKit 2 lays out only the
    /// viewport it believes is on screen and left the paper blank after a pinch.
    private let textView = PaperTextView(usingTextLayoutManager: false)
    private var storage: NSTextStorage { textView.textStorage! }
    private var editing = false
    private var pendingSave: DispatchWorkItem?
    private var watcher: FolderWatcher?
    private var pendingDiskCheck: DispatchWorkItem?
    private lazy var appearancePopover = ReadingPopover { [weak self] in self?.readingChanged() }
    private lazy var datePopover = DatePopover()
    private lazy var indexPopover = IndexPopover(
        onTitle: { [weak self] range in self?.show(range) },
        onTag: { [weak self] tag in self?.lookFor(tag) })
    private lazy var search = NotebookSearch(identifier: .init("search"), textView: textView,
        reveal: { [weak self] range in self?.reveal(range) },
        finish: { [weak self] match in
            guard let self else { return }
            if let match { self.textView.breakUndoCoalescing(); self.textView.setSelectedRange(match) }
            self.window?.makeFirstResponder(self.textView)
        })
    /// The writing line, as a fraction of the window height.
    private static let writingLine: CGFloat = 0.45

    init(store: NotebookStore) {
        self.store = store
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Essais"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false   // ⌘W keeps it, to come back from the Dock
        window.minSize = NSSize(width: 420, height: 420)
        window.backgroundColor = Paper.sheet
        super.init(window: window)
        window.delegate = self

        let toolbar = NSToolbar(identifier: "notebook")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsDisplayModeCustomization = false   // no "Icon and Text" menu on a right click
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        setUpPaper()
        // The first time, a size that fits the screen (a MacBook Air is 832 pt tall); after that the
        // window comes back as you left it.
        if UserDefaults.standard.string(forKey: "NSWindow Frame Notebook") == nil, let screen = NSScreen.main?.visibleFrame {
            let size = NSSize(width: min(1000, (screen.width * 0.72).rounded()), height: min(860, (screen.height * 0.9).rounded()))
            window.setFrame(NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2, width: size.width, height: size.height), display: false)
        }
        window.setFrameAutosaveName("Notebook")
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setUpPaper() {
        scrollView.drawsBackground = false
        // Like Safari: overlay scrollers that only show while scrolling, no horizontal bar
        // (the trackpad still pans when zoomed in), and pinch never goes below actual size.
        scrollView.scrollerStyle = .overlay
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 1
        scrollView.maxMagnification = 3
        scrollView.automaticallyAdjustsContentInsets = false

        let tv = textView
        tv.delegate = self
        tv.fileForDay = { [store] key in store.directory.appendingPathComponent(key + ".md") }
        tv.isRichText = true
        tv.importsGraphics = false
        tv.usesFontPanel = false
        tv.allowsUndo = true
        // Years of writing: only what is near the screen is laid out (the whole text took a second).
        tv.layoutManager?.allowsNonContiguousLayout = true
        tv.drawsBackground = false
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.lineFragmentPadding = 0
        tv.insertionPointColor = .controlAccentColor
        tv.restoreSpelling()
        tv.setAccessibilityLabel("Essais")
        tv.rotors = NotebookRotors(textView: tv)
        tv.onShow = { [weak self] range in self?.follow(range) }
        tv.onSmartMagnify = { [weak self] event in self?.smartMagnify(event) }
        tv.onPage = { [weak self] direction in self?.page(direction) }
        tv.controlAreas = { [weak self] in self?.controlAreas() ?? [] }
        tv.isTitleBar = { [weak self] event in self?.controlAreas().first?.contains(event.locationInWindow) ?? false }
        tv.onBecomeFirstResponder = { [weak self] in self?.search.textTookFocus() }
        tv.clearSelectionForComposing = { [weak self] in self?.clearSeamedSelection() }
        tv.textStorage?.delegate = self
        scrollView.documentView = tv
        // The hand always wins: a pinch or a scroll takes over from any move under way.
        for name in [NSScrollView.willStartLiveScrollNotification, NSScrollView.willStartLiveMagnifyNotification] {
            NotificationCenter.default.addObserver(forName: name, object: scrollView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.camera.stop() }
            }
        }
        let container = PaperContainer()
        container.paper = scrollView
        container.navigator = search.navigator
        scrollView.autoresizingMask = [.width, .height]
        container.addSubview(scrollView)
        container.addSubview(search.navigator)
        window!.contentView = container
        // The paper is as wide as the window (at least one column) and keeps that width while
        // zooming, like a web page in Safari: pinching only moves the camera.
        let clip = scrollView.contentView
        clip.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.fitPaper() }
        }
    }

    /// The toolbar band across the top, and the search capsule while it shows (window coordinates).
    private func controlAreas() -> [NSRect] {
        guard let window, let content = window.contentView else { return [] }
        let band = window.contentLayoutRect.maxY
        var areas = [NSRect(x: 0, y: band, width: content.bounds.width, height: content.bounds.height - band)]
        if !search.navigator.isHidden { areas.append(search.navigator.convert(search.navigator.bounds, to: nil)) }
        return areas
    }

    private func fitPaper() {
        let width = scrollView.contentView.frame.width.rounded()
        let rewraps = PaperTextView.columnWidth(for: width) != PaperTextView.columnWidth(for: textView.frame.width)
        // Full screen, tiling and Split View don't announce a resize: the place is taken here, before
        // the text re-wraps, whatever caused the change.
        let anchor = rewraps && resizeAnchor == nil && window?.isVisible == true ? readingAnchor() : nil
        textView.paperWidth = width
        guard abs(textView.frame.width - width) >= 1 else { return }
        textView.setFrameSize(NSSize(width: width, height: textView.frame.height))
        if let anchor { restore(anchor) }
    }

    // MARK: - Writing line

    /// Room below the text so the last line can rise to the writing line.
    private func updateInsets() {
        // The clip's frame, not its bounds: those shrink with the zoom, and what is enough at actual
        // size is enough closer in. The writing line doesn't depend on the camera.
        let height = scrollView.contentView.frame.height
        textView.bottomRoom = (height * (1 - Self.writingLine)).rounded()
        // Short notebooks still fill the window, so a click anywhere below the text lands in it.
        textView.minSize = NSSize(width: 0, height: height)
    }

    /// Writing at the end of the notebook: the line stays on the writing line, like a typewriter.
    /// Editing anywhere else, the paper stays put unless the caret would leave the view.
    private func follow(_ range: NSRange) {
        let atEnd = range.length == 0 && range.location == storage.length && textView.selectedRange().location == storage.length
        if atEnd { centerCaret(animated: true) } else { keepVisible(range) }
    }

    /// Height covered by the toolbar at the top, in paper coordinates.
    private var topBand: CGFloat {
        let band = window.map { $0.frame.height - $0.contentLayoutRect.height } ?? 52
        return band / scrollView.magnification
    }

    /// The least movement that shows `range` below the toolbar and above the bottom edge.
    private func keepVisible(_ range: NSRange) {
        guard let lm = textView.layoutManager, let container = textView.textContainer else { return }
        var rect: NSRect
        if range.location >= storage.length, !lm.extraLineFragmentRect.isEmpty {
            rect = lm.extraLineFragmentRect
        } else {
            let glyphs = lm.glyphRange(forCharacterRange: NSRange(location: min(range.location, max(0, storage.length - 1)), length: max(1, min(range.length, storage.length - range.location))), actualCharacterRange: nil)
            rect = lm.boundingRect(forGlyphRange: glyphs, in: container)
        }
        rect.origin.y += textView.textContainerOrigin.y
        let clip = scrollView.contentView
        // With the search capsule floating there, a little lower.
        let top = clip.bounds.minY + topBand + (search.isActive ? (NotebookSearch.height + 16) / scrollView.magnification : 8), bottom = clip.bounds.maxY - 24
        var y = clip.bounds.minY
        if rect.height > bottom - top { if rect.maxY < top || rect.minY > bottom { y = rect.minY - topBand - 8 } }
        else if rect.minY < top { y -= top - rect.minY }
        else if rect.maxY > bottom { y += rect.maxY - bottom }
        y = min(max(y, -topBand), max(0, textView.frame.height - clip.bounds.height))
        glide(to: y.rounded())
    }

    /// Page Down: the last line in view becomes the first under the toolbar. Page Up: the first under
    /// the toolbar becomes the last in view. No line is skipped, however the toolbar covers the paper
    /// and whatever heights TextKit is still estimating for text it hasn't laid out.
    private func page(_ direction: Int) {
        guard let lm = textView.layoutManager, let container = textView.textContainer, storage.length > 0 else { return }
        let clip = scrollView.contentView.bounds
        let origin = textView.textContainerOrigin.y
        let probe = direction > 0 ? clip.maxY - 2 : clip.minY + topBand + 2
        let line = lm.characterIndexForGlyph(at: lm.glyphIndex(for: NSPoint(x: 1, y: probe - origin), in: container))
        func target() -> CGFloat? {
            guard let rect = rect(at: line) else { return nil }
            return direction > 0 ? rect.minY - topBand - 4 : rect.maxY - clip.height + 4
        }
        land(near: line, floor: 0, target: target)
    }

    /// Takes the paper straight to `target()`, which measures a line near `location`. Heights of text not
    /// yet laid out are estimates, and landing on them leaves you elsewhere: the text around it is laid out
    /// first (more than any window shows), and since drawing can still settle a height and re-anchor the
    /// view, it's measured again until the line holds still.
    private func land(near location: Int, floor: CGFloat, target: () -> CGFloat?) {
        guard let lm = textView.layoutManager, storage.length > 0 else { return }
        camera.stop()
        let start = max(0, location - 8000)
        lm.ensureLayout(forCharacterRange: NSRange(location: start, length: min(16000, storage.length - start)))
        textView.sizeToFit()
        let paper = scrollView.contentView
        for _ in 0..<4 {
            guard let y = target() else { return }
            let to = min(max(floor, y), max(0, textView.frame.height - paper.bounds.height)).rounded()
                if abs(paper.bounds.minY - to) < 1 { break }
            paper.scroll(to: NSPoint(x: paper.bounds.minX, y: to))
            scrollView.reflectScrolledClipView(paper)
            window?.displayIfNeeded()
        }
    }

    /// Moves the paper on its springs, whatever it was doing. With Reduce Motion, or far away, it just goes.
    private func glide(to y: CGFloat, animated: Bool = true) {
        let clip = scrollView.contentView
        let target = NSPoint(x: followedX(), y: y)
        guard camera.isMoving || abs(y - clip.bounds.minY) >= 1 || abs(target.x - clip.bounds.minX) >= 1 else { return }
        // Far away, it just goes there: years of text flying by say nothing.
        guard animated, !isFar(y), !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, window?.isVisible == true else {
            camera.stop()
            clip.scroll(to: target)
            scrollView.reflectScrolledClipView(clip)
            return
        }
        camera.move(to: target)
    }

    private func isFar(_ y: CGFloat) -> Bool {
        let clip = scrollView.contentView.bounds
        return abs(y - clip.minY) > clip.height * 2
    }

    /// Zoomed in, the paper also moves sideways so the caret never leaves the screen.
    private func followedX() -> CGFloat {
        let clip = scrollView.contentView
        // caretRect knows the empty line after a Return. Measuring the last character instead took the line
        // break above, which runs to the end of the column, and sent the paper the wrong way.
        guard scrollView.magnification > 1.01, let line = caretRect() else { return clip.bounds.minX }
        let atEnd = textView.selectedRange().location >= storage.length && (textView.layoutManager?.extraLineFragmentRect.isEmpty ?? true)
        let x = atEnd ? line.maxX : line.minX
        let margin = clip.bounds.width * 0.15
        var minX = clip.bounds.minX
        if x < minX + margin { minX = x - margin } else if x > clip.bounds.maxX - margin { minX = x - clip.bounds.width + margin }
        return max(0, min(minX, textView.frame.width - clip.bounds.width))
    }

    /// Keeps the caret's line at the writing line, at any zoom: the paper moves, not your eyes.
    func centerCaret(animated: Bool = false) {
        let clip = scrollView.contentView
        guard clip.bounds.height > 0 else { return }
        guard let line = caretRect() else { return }
        let maxY = max(0, textView.frame.height - clip.bounds.height)
        let y = min(max(0, (line.midY - clip.bounds.height * Self.writingLine).rounded()), maxY)
        glide(to: y, animated: animated)
    }

    private func caretRect() -> NSRect? {
        guard let lm = textView.layoutManager, let container = textView.textContainer else { return nil }
        let location = textView.selectedRange().location
        var rect: NSRect
        if location >= storage.length, !lm.extraLineFragmentRect.isEmpty {
            rect = lm.extraLineFragmentRect
        } else if storage.length > 0 {
            let glyph = lm.glyphIndexForCharacter(at: min(location, storage.length - 1))
            rect = lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        } else {
            return nil
        }
        guard rect.height > 0 else { return nil }
        rect.origin.x += textView.textContainerOrigin.x
        rect.origin.y += textView.textContainerOrigin.y
        return rect
    }

    // MARK: - Camera and text size

    /// ⌘+ / ⌘− change the text size; ⌘0 puts text and camera back as they were.
    @objc func bigger(_ sender: Any?) { changeSize(by: 1) }
    @objc func smaller(_ sender: Any?) { changeSize(by: -1) }

    private func changeSize(by delta: CGFloat) {
        let before = Reading.size
        Reading.size += delta
        guard Reading.size != before else { NSSound.beep(); return }
        readingChanged()
        announceSize()
    }

    @objc func pickFont(_ sender: NSMenuItem) {
        guard let font = sender.representedObject as? String, let choice = Fonts(rawValue: font) else { return }
        Reading.font = choice
        readingChanged()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(bigger(_:)): return Reading.size < Reading.sizes.upperBound
        case #selector(smaller(_:)): return Reading.size > Reading.sizes.lowerBound
        case #selector(actualSize(_:)): return scrollView.magnification > 1.01
        case #selector(bold(_:)), #selector(italic(_:)), #selector(heading(_:)):
            return window?.firstResponder === textView
        case #selector(pickFont(_:)):
            item.state = item.representedObject as? String == Reading.font.rawValue ? .on : .off
            return true
        default: return true
        }
    }

    /// VoiceOver says the new size, as the system does for its own text size controls.
    func announceSize() {
        NSAccessibility.post(element: textView, notification: .announcementRequested, userInfo: [
            .announcement: Reading.sizeAnnouncement,
            .priority: NSAccessibilityPriorityLevel.medium.rawValue,
        ])
    }
    /// ⌘0 undoes the pinch; the text size is a reading choice and stays.
    @objc func actualSize(_ sender: Any?) { zoom(to: 1) }

    /// Two-finger double tap: closer around the point you tapped, or back to actual size.
    /// Two-finger double tap, like Safari: the column fills the window (the text block you tapped,
    /// at reading size), or back to actual size. Narrow windows, where the column already fills it,
    /// get a plain closer look at the point.
    private func smartMagnify(_ event: NSEvent) {
        let point = textView.convert(event.locationInWindow, from: nil)
        if scrollView.magnification > 1.01 { return zoom(to: 1, around: point) }
        let width = scrollView.contentView.frame.width
        let fill = width / (PaperTextView.columnWidth(for: width) + 48)
        if fill < 1.15 { return zoom(to: 1.6, around: point) }
        zoom(to: fill, around: NSPoint(x: textView.frame.midX, y: point.y))
    }

    private func zoom(to value: CGFloat, around point: NSPoint? = nil) {
        let clip = scrollView.contentView
        let center = point ?? NSPoint(x: clip.bounds.midX, y: clip.bounds.midY)
        let target = min(max(value, scrollView.minMagnification), scrollView.maxMagnification)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            camera.stop()
            scrollView.setMagnification(target, centeredAt: center)
        } else {
            camera.zoom(to: target, around: center)
        }
        updateInsets()
    }

    // MARK: - Loading and saving

    func load() {
        #if QA
        store.seedIfEmpty()
        #endif
        var days = store.load()
        // Today's date line waits for you, like a fresh page: what you write goes under it. An empty
        // day is never saved, so a day you don't write in leaves nothing behind. It takes its place
        // in time (a day dated later, from another editor, stays after it) and is never there twice.
        if !days.contains(where: { $0.key == todayKey }) {
            days.append(Day(key: todayKey, date: Date(), text: ""))
            days.sort { $0.key < $1.key }
        }
        let text = NSMutableAttributedString()
        for (i, day) in days.enumerated() {
            text.append(Reading.dateLine(day.date, day: day.key))
            let body = day.text + (i < days.count - 1 ? "\n" : "")
            text.append(NSAttributedString(string: body, attributes: Reading.bodyAttributes(day: day.key)))
        }
        Markdown.style(text, in: NSRange(location: 0, length: text.length))
        editing = true
        storage.setAttributedString(text)
        editing = false
        // The old ranges no longer exist; undoing into them would corrupt the text.
        textView.undoManager?.removeAllActions()
        textView.typingAttributes = Reading.bodyAttributes(day: NotebookStore.key(Date()))
        dirtyDays = []
        tellUnreadable()
    }

    /// Days whose files couldn't be read aren't in the notebook: said once, with the way to see them.
    private var toldUnreadable: Set<String> = []
    private func tellUnreadable() {
        let news = Set(store.unreadable).subtracting(toldUnreadable)
        toldUnreadable.formUnion(news)
        guard let first = news.sorted().first else { return }
        // After the window is on screen: the sheet needs it.
        DispatchQueue.main.async { [self] in
            guard let window, !telling else { return }
            telling = true
            let alert = NSAlert()
            alert.messageText = news.count == 1 ? String(localized: "The writing of \(NotebookIndex.longDate(first)) couldn’t be read")
                                                : String(localized: "\(news.count) days couldn’t be read")
            alert.informativeText = String(localized: "Their files are in the Essais folder, untouched, but they aren’t in the notebook. They may still be downloading from iCloud.")
            alert.addButton(withTitle: String(localized: "OK"))
            alert.addButton(withTitle: String(localized: "Show in Finder"))
            let files = news.sorted().map { store.directory.appendingPathComponent($0 + ".md") }
            alert.beginSheetModal(for: window) { [weak self] response in
                if response == .alertSecondButtonReturn { NSWorkspace.shared.activateFileViewerSelecting(files) }
                self?.telling = false
            }
        }
    }

    // MARK: - Changes made elsewhere

    /// After midnight with the app open, the new day's date line joins the end. Appending never
    /// moves earlier text, so undo stays valid. A sentence isn't cut in two by the clock: while you're
    /// writing you stay in the day of the session, and the date waits for a pause.
    private func dayChanged() {
        pendingDayChange?.cancel()
        let quiet = Date().timeIntervalSince(lastTyped)
        if quiet < newDayPause, (storage.length > 0 ? storage.attribute(.day, at: storage.length - 1, effectiveRange: nil) as? String : nil).map({ $0 < todayKey }) ?? true {
            let work = DispatchWorkItem { [weak self] in self?.dayChanged() }
            pendingDayChange = work
            DispatchQueue.main.asyncAfter(deadline: .now() + newDayPause - quiet + 0.1, execute: work)
            return
        }
        let lastKey = storage.length > 0 ? storage.attribute(.day, at: storage.length - 1, effectiveRange: nil) as? String : nil
        // A day already in the notebook (a flight west, the clock set back) doesn't open a second time.
        guard lastKey.map({ $0 < todayKey }) ?? true else { return }
        let atEnd = textView.selectedRange().location == storage.length
        let line = NSMutableAttributedString()
        if let lastKey { line.append(NSAttributedString(string: "\n", attributes: Reading.bodyAttributes(day: lastKey))) }
        line.append(Reading.dateLine(NotebookStore.date(todayKey) ?? Date(), day: todayKey))
        editing = true
        storage.append(line)
        editing = false
        if atEnd { textView.setSelectedRange(NSRange(location: storage.length, length: 0)) }
        textView.typingAttributes = Reading.bodyAttributes(day: todayKey)
    }

    private var lastTyped = Date.distantPast
    private var pendingDayChange: DispatchWorkItem?
    /// Ten minutes without typing and the session is over.
    var newDayPause: TimeInterval = 600

    /// Follows the folder: another Mac through iCloud, another editor, Finder.
    func startWatching() {
        for name in [Notification.Name.NSCalendarDayChanged, .NSSystemTimeZoneDidChange, .NSSystemClockDidChange] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dayChanged() }
            }
        }
        // iCloud can bring hundreds of files in a row: one look at the folder once they stop coming.
        watcher = FolderWatcher(store.directory) { [weak self] in
            guard let self else { return }
            self.pendingDiskCheck?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.diskChanged() }
            self.pendingDiskCheck = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.diskChanged(); self?.dayChanged() }
        }
    }

    /// Our own edits are written first: if the same day changed in both places, ours stays and the
    /// other one is kept beside it (see NotebookStore.save). Then whatever else changed comes in.
    private func diskChanged() {
        // While something couldn't be saved, the notebook is the only copy of it: never reload over it.
        guard saveNow().failed.isEmpty, store.changedOnDisk() else { return }
        reloadKeepingPlace()
    }

    /// Reloads the notebook and leaves the caret and the paper where they were, counted from the
    /// day they belong to, so a change in an earlier day doesn't move you.
    func reloadKeepingPlace() {
        let caret = place(of: textView.selectedRange().location)
        let clip = scrollView.contentView
        guard let lm = textView.layoutManager, let container = textView.textContainer else { return }
        let top = place(of: lm.characterIndexForGlyph(at: lm.glyphIndex(for: NSPoint(x: 0, y: clip.bounds.minY - textView.textContainerOrigin.y), in: container)))
        let topOffset = clip.bounds.minY - (rect(at: location(of: top))?.minY ?? clip.bounds.minY)
        load()
        search.refresh()
        textView.setSelectedRange(NSRange(location: location(of: caret), length: 0))
        if let line = rect(at: location(of: top)) {
            clip.setBoundsOrigin(NSPoint(x: clip.bounds.minX, y: max(0, line.minY + topOffset)))
            scrollView.reflectScrolledClipView(clip)
        }
    }

    /// (day, characters into that day's text); nil day means the end of the notebook.
    private func place(of location: Int) -> (day: String?, offset: Int) {
        guard location < storage.length,
              let day = storage.attribute(.day, at: location, effectiveRange: nil) as? String,
              let body = bodyStart(of: day) else { return (nil, 0) }
        return (day, max(0, location - body))
    }

    private func location(of place: (day: String?, offset: Int)) -> Int {
        guard let day = place.day, let body = bodyStart(of: day) else { return storage.length }
        var end = body
        storage.enumerateAttribute(.day, in: NSRange(location: body, length: storage.length - body)) { value, range, stop in
            if value as? String == day { end = NSMaxRange(range) } else { stop.pointee = true }
        }
        return min(body + place.offset, end)
    }

    /// Where a day's text starts, just after its date line.
    private func bodyStart(of day: String) -> Int? {
        var start: Int?
        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attrs, range, stop in
            if attrs[.day] as? String == day, attrs[.dateLine] == nil { start = range.location; stop.pointee = true }
        }
        return start
    }

    private func rect(at location: Int) -> NSRect? {
        guard let lm = textView.layoutManager, let container = textView.textContainer, storage.length > 0 else { return nil }
        let glyph = lm.glyphIndexForCharacter(at: min(location, storage.length - 1))
        var r = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        r.origin.y += textView.textContainerOrigin.y
        _ = container
        return r
    }

    func openAtEnd() {
        fitPaper()
        updateInsets()
        window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: endOfToday(), length: 0))
        DispatchQueue.main.async { [self] in restore(.writing) }
    }

    /// Where today's writing ends: the end of the notebook, unless a later day came from elsewhere.
    private func endOfToday() -> Int {
        var end = storage.length
        storage.enumerateAttribute(.day, in: NSRange(location: 0, length: storage.length), options: .reverse) { value, r, stop in
            if let key = value as? String, key <= todayKey { end = NSMaxRange(r); stop.pointee = true }
        }
        // Not past the line break that ends today, before a later day's date line.
        if end < storage.length, end > 0, (storage.string as NSString).character(at: end - 1) == 0x0A { end -= 1 }
        return end
    }

    /// The notebook's days as files hold them, or only some: years of days aren't rebuilt to save one.
    private func days(only keys: Set<String>? = nil) -> [Day] {
        var runs: [String: [NSRange]] = [:]
        var order: [String] = []
        var last: String?
        storage.enumerateAttribute(.day, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let key = value as? String else { return }
            last = key
            guard keys?.contains(key) ?? true else { return }
            if runs[key] == nil { order.append(key) }
            runs[key, default: []].append(range)
        }
        let ns = storage.mutableString
        return order.compactMap { key in
            guard let date = NotebookStore.date(key) else { return nil }
            var text = ""
            for run in runs[key] ?? [] {
                storage.enumerateAttribute(.dateLine, in: run) { value, range, _ in
                    if value == nil { text += ns.substring(with: range) }
                }
            }
            if key != last, text.hasSuffix("\n") { text.removeLast() }
            return Day(key: key, date: date, text: text)
        }
    }

    /// Days with changes not yet written, noted as the text changes.
    private var dirtyDays: Set<String> = []

    private func noteChange(in edited: NSRange) {
        let start = max(0, edited.location - 1)
        let around = NSRange(location: start, length: min(edited.length + 2, storage.length - start))
        storage.enumerateAttribute(.day, in: around) { value, _, _ in
            if let key = value as? String { dirtyDays.insert(key) }
        }
    }

    /// Writes what changed. `everything` looks at every day instead of the notes (leaving the app):
    /// the last word never depends on the bookkeeping being right.
    @discardableResult
    func saveNow(everything: Bool = false) -> NotebookStore.SaveReport {
        pendingSave?.cancel()
        guard everything || !dirtyDays.isEmpty else { return NotebookStore.SaveReport() }
        let report = store.save(everything ? days() : days(only: dirtyDays))
        dirtyDays = Set(report.failed.map(\.day))
        // A day that keeps failing is told about once, until it saves again; Essais keeps trying.
        let failing = Set(report.failed.map(\.day))
        let news = report.failed.filter { !toldFailing.contains($0.day) }
        toldFailing = failing
        if !report.keptAside.isEmpty || !news.isEmpty { tell(NotebookStore.SaveReport(keptAside: report.keptAside, failed: news)) }
        if !failing.isEmpty { scheduleSave(after: 5) }
        return report
    }
    private var toldFailing: Set<String> = []

    /// Something the writer must know: a day changed in two places, or a day couldn't be saved.
    /// A sheet on the window, once, with the way to see the files.
    private var telling = false
    private func tell(_ report: NotebookStore.SaveReport) {
        guard let window, !telling else { return }
        telling = true
        let alert = NSAlert()
        if let failed = report.failed.first {
            alert.alertStyle = .critical
            alert.messageText = String(localized: "The writing of \(NotebookIndex.longDate(failed.day)) couldn’t be saved")
            alert.informativeText = String(localized: "Essais will keep trying while it’s open. \(failed.error.localizedDescription)")
        } else {
            alert.messageText = String(localized: "A day changed in two places")
            alert.informativeText = String(localized: "Your version stays in the notebook. The other one was kept next to it, in the Essais folder, so nothing is lost.")
        }
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Show in Finder"))
        let files = report.keptAside.isEmpty ? [store.directory] : report.keptAside
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertSecondButtonReturn { NSWorkspace.shared.activateFileViewerSelecting(files) }
            self?.telling = false
        }
    }

    private func scheduleSave(after delay: Double = 1) {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Text still being composed isn't writing yet; it's saved when it's committed.
            if self.textView.hasMarkedText() { self.scheduleSave() } else { self.saveNow() }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Editing

    #if QA
    /// Tests can move the clock (--midnight).
    var debugToday: String?
    private var todayKey: String { debugToday ?? NotebookStore.key(Date()) }
    #else
    private var todayKey: String { NotebookStore.key(Date()) }
    #endif

    /// Date lines, and the line break that ends the day before each one, can't be edited: they
    /// are where one day's file ends and the next begins.
    private func protectedRanges(in range: NSRange) -> [NSRange] {
        var result: [NSRange] = []
        let lower = max(0, range.location - 1), upper = min(storage.length, NSMaxRange(range) + 1)
        storage.enumerateAttribute(.dateLine, in: NSRange(location: lower, length: upper - lower)) { value, r, _ in
            guard value != nil else { return }
            var full = NSRange()
            _ = storage.attribute(.dateLine, at: r.location, longestEffectiveRange: &full, in: NSRange(location: 0, length: storage.length))
            if full.location > 0 { full = NSRange(location: full.location - 1, length: full.length + 1) }   // the break before it
            if NSIntersectionRange(full, range).length > 0, !result.contains(full) { result.append(full) }
        }
        return result
    }

    /// Every change to the text comes through here (typing, paste, drag, transformations, Writing Tools).
    func textView(_ textView: NSTextView, shouldChangeTextInRanges affectedRanges: [NSValue], replacementStrings: [String]?) -> Bool {
        guard !editing else { return true }
        let ranges = affectedRanges.map(\.rangeValue)
        if ranges.count == 1 { return shouldChange(ranges[0], to: replacementStrings?.first) }
        // Several places at once (text moved by dragging it, multiple selections): only within days.
        if ranges.contains(where: { !protectedRanges(in: $0).isEmpty }) { NSSound.beep(); return false }
        return true
    }

    private func shouldChange(_ range: NSRange, to text: String?) -> Bool {
        let protected = protectedRanges(in: range)
        if !protected.isEmpty {
            // A rewrite of the selection itself (Transformations, Writing Tools) would carry its dates
            // into the text as words: across days, only deleting and writing over are allowed.
            let ns = storage.string as NSString
            if let text, !text.isEmpty, protected.contains(where: { p in
                let date = ns.substring(with: p).trimmingCharacters(in: .whitespacesAndNewlines)
                return !date.isEmpty && text.range(of: date, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }) { NSSound.beep(); return false }
            // Only the writing in the selection changes; the days' seams stay. Done right after this
            // callback, never inside it.
            let pieces = writing(in: range, around: protected)
            guard !pieces.isEmpty || !(text ?? "").isEmpty else { NSSound.beep(); return false }
            DispatchQueue.main.async { [weak self] in self?.replace(pieces, with: text ?? "", near: range) }
            return false
        }
        return true
    }

    /// What's in `range` without the seams.
    private func writing(in range: NSRange, around protected: [NSRange]) -> [NSRange] {
        var pieces: [NSRange] = []
        var cursor = range.location
        for p in protected.sorted(by: { $0.location < $1.location }) {
            if p.location > cursor { pieces.append(NSRange(location: cursor, length: p.location - cursor)) }
            cursor = max(cursor, NSMaxRange(p))
        }
        if NSMaxRange(range) > cursor { pieces.append(NSRange(location: cursor, length: NSMaxRange(range) - cursor)) }
        return pieces.filter { $0.length > 0 }
    }

    /// Before a composition starts over a selection that crosses days (see PaperTextView.setMarkedText).
    private func clearSeamedSelection() {
        let range = textView.selectedRange()
        guard !textView.hasMarkedText(), range.length > 0 else { return }
        let protected = protectedRanges(in: range)
        guard !protected.isEmpty else { return }
        let pieces = writing(in: range, around: protected)
        if pieces.isEmpty { textView.setSelectedRange(NSRange(location: bodyStartAfter(range.location), length: 0)) }
        else { replace(pieces, with: "", near: range) }
    }

    private func replace(_ pieces: [NSRange], with text: String, near range: NSRange) {
        var ranges = pieces
        var strings = Array(repeating: "", count: pieces.count)
        if !text.isEmpty {
            if ranges.isEmpty {
                // Typing over a selection made only of seams: write where the selection's day begins.
                let at = bodyStartAfter(range.location)
                ranges = [NSRange(location: at, length: 0)]; strings = [text]
            } else {
                strings[0] = text
            }
        }
        // Its own undo step, made of ordinary single changes, last first so the others' places hold. Applied as
        // one multiple change, AppKit left it out of the undo stack and everything before it went stale.
        textView.breakUndoCoalescing()
        textView.undoManager?.beginUndoGrouping()
        // Our own edit: the delegate would see the seams nearby and refuse it. The day comes from where each
        // piece lands (didProcessEditing), never from the typing attributes.
        let attributes = Reading.bodyAttributes(day: todayKey)
        for (r, string) in zip(ranges, strings).reversed() {
            editing = true
            let allowed = textView.shouldChangeText(in: r, replacementString: string)
            editing = false
            guard allowed else { continue }
            storage.replaceCharacters(in: r, with: NSAttributedString(string: string, attributes: attributes))
            textView.didChangeText()
        }
        textView.undoManager?.endUndoGrouping()
        textView.setSelectedRange(NSRange(location: ranges[0].location + (strings[0] as NSString).length, length: 0))
        textView.breakUndoCoalescing()
    }

    /// The first place after `location` where writing can go (past any date line).
    private func bodyStartAfter(_ location: Int) -> Int {
        var at = min(location, storage.length)
        while at < storage.length, storage.attribute(.dateLine, at: at, effectiveRange: nil) != nil {
            var r = NSRange(); _ = storage.attribute(.dateLine, at: at, effectiveRange: &r); at = NSMaxRange(r)
        }
        return at
    }

    /// The caret never rests inside a date line: it goes to the start of that day's writing, as if
    /// the date were printed on the page. Selections that span days are left alone (to copy them).
    func textView(_ textView: NSTextView, willChangeSelectionFromCharacterRange old: NSRange, toCharacterRange new: NSRange) -> NSRange {
        if new.length > 0, let over = selection(from: old, overDateTo: new) { return over }
        guard new.location < storage.length, storage.attribute(.dateLine, at: new.location, effectiveRange: nil) != nil else { return new }
        var line = NSRange()
        _ = storage.attribute(.dateLine, at: new.location, longestEffectiveRange: &line, in: NSRange(location: 0, length: storage.length))
        if new.length == 0 || NSMaxRange(new) <= NSMaxRange(line) {
            // Moving up from a day's first line skips its date and lands in the day before.
            if new.length == 0, old.location == NSMaxRange(line), new.location < old.location, line.location > 0 {
                return NSRange(location: line.location - 1, length: 0)
            }
            return NSRange(location: NSMaxRange(line), length: 0)
        }
        return new
    }

    /// Extending a selection (⇧ and arrows, a drag), the end that moves goes over a date line whole,
    /// never letter by letter, and never gets stuck at the start of a day.
    private func selection(from old: NSRange, overDateTo new: NSRange) -> NSRange? {
        func line(at location: Int) -> NSRange? {
            guard location < storage.length, storage.attribute(.dateLine, at: location, effectiveRange: nil) != nil else { return nil }
            var line = NSRange()
            _ = storage.attribute(.dateLine, at: location, longestEffectiveRange: &line, in: NSRange(location: 0, length: storage.length))
            return line
        }
        let end = NSMaxRange(new)
        if new.location != old.location, end == NSMaxRange(old), let date = line(at: new.location) {
            if new.location > old.location { return NSRange(location: min(NSMaxRange(date), end), length: max(0, end - NSMaxRange(date))) }
            guard date.location > 0 else { return old }
            return NSRange(location: date.location - 1, length: end - date.location + 1)
        }
        if new.location == old.location, end != NSMaxRange(old), let date = line(at: end) {
            let to = end > NSMaxRange(old) ? NSMaxRange(date) : max(new.location, date.location - 1)
            return NSRange(location: new.location, length: to - new.location)
        }
        return nil
    }

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        // New text belongs to the day it lands in, whatever it carried (dragged or pasted from another
        // day) and is never a date line. Undo and redo put back exactly what was there.
        let undoing = textView.undoManager?.isUndoing == true || textView.undoManager?.isRedoing == true
        // Text still being composed (a dead key, an input method) is settled when it's committed.
        if editedRange.length > 0, !editing, !undoing, !textView.hasMarkedText() {
            // A day is everything after its date line. Several changes at once arrive as one range that
            // can hold real date lines (a whole paragraph each): those stay and start the next day.
            var day = (editedRange.location > 0 ? textStorage.attribute(.day, at: editedRange.location - 1, effectiveRange: nil) as? String : nil)
                ?? (NSMaxRange(editedRange) < textStorage.length ? textStorage.attribute(.day, at: NSMaxRange(editedRange), effectiveRange: nil) as? String : nil)
                ?? todayKey
            let ns = textStorage.string as NSString
            let all = NSRange(location: 0, length: textStorage.length)
            textStorage.enumerateAttribute(.dateLine, in: editedRange) { value, r, _ in
                if value != nil {
                    var line = NSRange()
                    _ = textStorage.attribute(.dateLine, at: r.location, longestEffectiveRange: &line, in: all)
                    if line.location == 0 || ns.character(at: line.location - 1) == 0x0A {
                        day = textStorage.attribute(.day, at: r.location, effectiveRange: nil) as? String ?? day
                        return
                    }
                }
                // Plain text in plain files: whatever came in (links, colors, fonts from a web page, a
                // date line's look) takes the look of the writing; Markdown.style below adds the rest.
                textStorage.setAttributes(Reading.bodyAttributes(day: day), range: r)
            }
        }
        noteChange(in: editedRange)
        // Our own wholesale changes (loading, new type) come already styled. Otherwise the paragraphs on
        // both sides of the edit: deleting a # or splitting a title changes what the neighbours are.
        if !editing {
            let start = max(0, editedRange.location - 1)
            Markdown.style(textStorage, in: NSRange(location: start, length: min(editedRange.length + 2, textStorage.length - start)))
        }
    }

    /// Dates and #tags aren't misspelled words.
    func textView(_ textView: NSTextView, shouldSetSpellingState value: Int, range: NSRange) -> Int {
        guard value != 0, NSMaxRange(range) <= storage.length, range.length > 0 else { return value }
        if storage.attribute(.dateLine, at: range.location, effectiveRange: nil) != nil { return 0 }
        let ns = storage.mutableString
        guard ns.character(at: max(0, range.location - 1)) == 0x23 || ns.substring(with: range).contains("#") else { return value }
        let paragraph = ns.paragraphRange(for: range)
        for m in Markdown.tag.matches(in: storage.string, range: paragraph) where NSIntersectionRange(m.range, range).length > 0 { return 0 }
        return value
    }

    /// What you type next takes the look of the writing around the caret, never a date line's.
    func textViewDidChangeSelection(_ notification: Notification) {
        guard !editing, !textView.hasMarkedText() else { return }
        let at = textView.selectedRange().location
        let day = (at > 0 ? storage.attribute(.day, at: at - 1, effectiveRange: nil) as? String : nil)
            ?? (at < storage.length ? storage.attribute(.day, at: at, effectiveRange: nil) as? String : nil) ?? todayKey
        if textView.typingAttributes[.dateLine] != nil || textView.typingAttributes[.day] as? String != day {
            textView.typingAttributes = Reading.bodyAttributes(day: day)
        }
        // The caret skips date lines, so VoiceOver would never say one: crossing into another day says it.
        if day != caretDay {
            if caretDay != nil, NSWorkspace.shared.isVoiceOverEnabled {
                NSAccessibility.post(element: textView, notification: .announcementRequested,
                                     userInfo: [.announcement: NotebookIndex.longDate(day), .priority: NSAccessibilityPriorityLevel.medium.rawValue])
            }
            caretDay = day
        }
    }
    private var caretDay: String?

    func textDidChange(_ notification: Notification) {
        lastTyped = Date()
        scheduleSave()
        search.refresh()
    }

    // MARK: - Format: writes the marks, which stay visible

    @objc func bold(_ sender: Any?) { emphasize(marks: 2) }
    @objc func italic(_ sender: Any?) { emphasize(marks: 1) }
    /// ⌘1 ⌘2 ⌘3: the line becomes that level of title; pressed again, plain text.
    @objc func heading(_ sender: NSMenuItem) { setHeading(level: sender.tag) }

    /// One edit, undone on its own, that leaves `selection` selected.
    private func write(_ text: String, over range: NSRange, select selection: NSRange) {
        textView.breakUndoCoalescing()
        // Not insertText: at the start of a day it takes the look of the date line above, and then it
        // counts as part of it. The day comes from where the text lands (didProcessEditing).
        guard textView.shouldChangeText(in: range, replacementString: text) else { return }
        storage.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: Reading.bodyAttributes(day: todayKey)))
        textView.didChangeText()
        textView.breakUndoCoalescing()
        textView.setSelectedRange(selection)
    }

    /// Around the selection, or at the caret. `***` is bold and italic: each of the two comes and goes on its own.
    private func emphasize(marks: Int) {
        var inner = textView.selectedRange()
        guard protectedRanges(in: inner).isEmpty else { NSSound.beep(); return }
        let ns = storage.mutableString
        let star: unichar = 0x2A
        // Spaces at the edges stay out, or the marks wouldn't count as emphasis; marks selected too are marks.
        while inner.length > 0, let last = UnicodeScalar(ns.character(at: NSMaxRange(inner) - 1)), CharacterSet.whitespacesAndNewlines.contains(last) { inner.length -= 1 }
        while inner.length > 0, let first = UnicodeScalar(ns.character(at: inner.location)), CharacterSet.whitespacesAndNewlines.contains(first) { inner.location += 1; inner.length -= 1 }
        while inner.length >= 2, ns.character(at: inner.location) == star, ns.character(at: NSMaxRange(inner) - 1) == star {
            inner = NSRange(location: inner.location + 1, length: inner.length - 2)
        }
        var left = 0, right = 0
        while inner.location - left > 0, ns.character(at: inner.location - left - 1) == star { left += 1 }
        while NSMaxRange(inner) + right < ns.length, ns.character(at: NSMaxRange(inner) + right) == star { right += 1 }
        let around = min(left, right)
        let has = marks == 2 ? around >= 2 : around % 2 == 1
        let count = has ? around - marks : around + marks
        let mark = String(repeating: "*", count: count)
        let whole = NSRange(location: inner.location - around, length: inner.length + around * 2)
        let text = mark + ns.substring(with: inner) + mark
        write(text, over: whole, select: NSRange(location: whole.location + count, length: inner.length))
    }

    private func setHeading(level: Int) {
        let selection = textView.selectedRange()
        let ns = storage.mutableString
        let line = ns.lineRange(for: NSRange(location: selection.location, length: 0))
        guard line.length > 0 || selection.location == ns.length, selection.location >= storage.length || storage.attribute(.dateLine, at: selection.location, effectiveRange: nil) == nil else { NSSound.beep(); return }
        var marks = 0
        while marks < 3, marks < line.length, ns.character(at: line.location + marks) == 0x23 { marks += 1 }
        let hasSpace = marks > 0 && line.location + marks < ns.length && ns.character(at: line.location + marks) == 0x20
        let old = hasSpace ? marks + 1 : 0
        let new = hasSpace && marks == level ? "" : String(repeating: "#", count: level) + " "
        let length = (new as NSString).length
        let moved = { (at: Int) in max(line.location + length, at + length - old) }
        write(new, over: NSRange(location: line.location, length: old),
              select: NSRange(location: moved(selection.location), length: selection.length))
    }

    // MARK: - Reading choices (the type itself, for legibility)

    /// New type shows at once. With years of text that takes a moment, so pressing ⌘+ again and again
    /// waits for the last press instead of laying out every size on the way.
    func readingChanged() {
        pendingReading?.cancel()
        guard lastReadingCost > 0.1 else { return applyReading() }
        let work = DispatchWorkItem { [weak self] in self?.applyReading() }
        pendingReading = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
    private var pendingReading: DispatchWorkItem?
    private var lastReadingCost: TimeInterval = 0

    private func applyReading() {
        let started = Date()
        defer { lastReadingCost = Date().timeIntervalSince(started) }
        let anchor = readingAnchor()
        restyle()
        textView.updateInset()   // the column is measured in em
        updateInsets()
        restore(anchor)
        search.refresh()
    }

    /// New font or size, applied to the text in place: nothing is reloaded, undo stays valid.
    private func restyle() {
        let all = NSRange(location: 0, length: storage.length)
        editing = true
        storage.beginEditing()
        storage.enumerateAttribute(.dateLine, in: all) { value, r, _ in
            if value != nil, let key = storage.attribute(.day, at: r.location, effectiveRange: nil) as? String, let date = NotebookStore.date(key) {
                storage.setAttributes(Reading.dateLine(date, day: key).attributes(at: 0, effectiveRange: nil), range: r)
            } else if value == nil {
                storage.enumerateAttribute(.day, in: r) { day, rr, _ in
                    storage.setAttributes(Reading.bodyAttributes(day: day as? String ?? todayKey), range: rr)
                }
            }
        }
        Markdown.style(storage, in: all)
        storage.endEditing()
        editing = false
        textView.typingAttributes = Reading.bodyAttributes(day: (storage.length > 0 ? storage.attribute(.day, at: storage.length - 1, effectiveRange: nil) as? String : nil) ?? todayKey)
    }

    /// Where you are, to come back to after the text re-wraps (new size, new font, new width):
    /// writing at the end → the writing line; otherwise the first line under the toolbar.
    private enum Anchor { case writing, line(location: Int, offset: CGFloat) }

    private func readingAnchor() -> Anchor {
        let clip = scrollView.contentView.bounds
        let caret = textView.selectedRange()
        if caret.length == 0, caret.location == storage.length, let line = caretRect(), line.minY >= clip.minY, line.maxY <= clip.maxY {
            return .writing
        }
        guard let lm = textView.layoutManager, let container = textView.textContainer else { return .writing }
        let point = NSPoint(x: 1, y: clip.minY + topBand - textView.textContainerOrigin.y)
        let location = lm.characterIndexForGlyph(at: lm.glyphIndex(for: point, in: container))
        let offset = (rect(at: location)?.minY ?? clip.minY) - clip.minY
        return .line(location: location, offset: offset)
    }

    private func restore(_ anchor: Anchor) {
        switch anchor {
        case .writing:
            land(near: textView.selectedRange().location, floor: 0) { [self] in
                caretRect().map { $0.midY - scrollView.contentView.bounds.height * Self.writingLine }
            }
        case .line(let location, let offset):
            land(near: location, floor: -topBand) { [self] in rect(at: location).map { $0.minY - offset } }
        }
    }

    @objc func showReading(_ sender: Any?) {
        guard let item = window?.toolbar?.items.first(where: { $0.itemIdentifier.rawValue == "reading" }) else { return }
        indexPopover.close()
        appearancePopover.toggle(from: item)
    }

    // MARK: - Index and search

    /// ⇧⌘T, as in Calendar: a month of the notebook; a day takes you to the first writing on or after it.
    @objc func goToDate(_ sender: Any?) {
        guard let item = window?.toolbar?.items.first(where: { $0.itemIdentifier.rawValue == "index" }) else { return }
        var lines: [(key: String, range: NSRange)] = []
        storage.enumerateAttribute(.dateLine, in: NSRange(location: 0, length: storage.length)) { value, r, _ in
            if value != nil, let key = storage.attribute(.day, at: r.location, effectiveRange: nil) as? String { lines.append((key, r)) }
        }
        guard let first = lines.first, let firstDate = NotebookStore.date(first.key) else { return }
        let written = Set(days().filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map(\.key))
        indexPopover.close()
        if appearancePopover.isShown { appearancePopover.closeNow() }
        datePopover.show(from: item, written: written, first: firstDate) { [weak self] key in
            guard let self else { return }
            let target = lines.first { $0.key >= key && written.contains($0.key) } ?? lines.first { $0.key >= key } ?? lines.last!
            self.show(target.range)
        }
    }

    @objc func showIndex(_ sender: Any?) {
        guard let item = window?.toolbar?.items.first(where: { $0.itemIdentifier.rawValue == "index" }) else { return }
        if appearancePopover.isShown { appearancePopover.closeNow() }
        indexPopover.toggle(from: item, index: NotebookIndex(storage))
    }

    /// ⌘F or a click: the magnifying glass stretches into the field (AppKit's own animation).
    @objc func showSearch(_ sender: Any?) {
        indexPopover.close()
        if appearancePopover.isShown { appearancePopover.closeNow() }
        search.begin()
    }
    /// A tag from the index: all its appearances in the search, starting from the most recent.
    private func lookFor(_ text: String) {
        showSearch(nil)
        DispatchQueue.main.async { [self] in search.look(for: text) }
    }

    @objc func findNext(_ sender: Any?) { if search.isActive { search.showNext(sender) } else { showSearch(sender) } }
    @objc func findPrevious(_ sender: Any?) { if search.isActive { search.showPrevious(sender) } else { showSearch(sender) } }
    @objc func useSelectionForFind(_ sender: Any?) { search.useSelection(); showSearch(sender) }

    /// Brings a title or a tag into view, a third of the way down, and points at it. The caret
    /// waits at the end of that paragraph, ready to add a line.
    func show(_ range: NSRange) {
        scroll(to: range, always: true) { [weak self] in
            guard let self else { return }
            let line = (self.storage.string as NSString).lineRange(for: NSRange(location: range.location, length: 0))
            self.window?.makeFirstResponder(self.textView)
            self.textView.breakUndoCoalescing()
            self.textView.setSelectedRange(NSRange(location: line.location + max(0, line.length - 1), length: 0))
            let mark = range.length > 1 && range.length < 80 ? range : NSRange(location: line.location, length: max(0, line.length - 1))
            self.textView.showFindIndicator(for: mark)
        }
    }

    /// A search match: the paper moves only if the match is out of comfortable view.
    private func reveal(_ range: NSRange) {
        scroll(to: range, always: false) { [weak self] in self?.textView.showFindIndicator(for: range) }
    }

    private func scroll(to range: NSRange, always: Bool, then done: @escaping () -> Void) {
        guard let lm = textView.layoutManager, let container = textView.textContainer, NSMaxRange(range) <= storage.length else { return }
        let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = lm.boundingRect(forGlyphRange: glyphs, in: container)
        rect.origin.x += textView.textContainerOrigin.x
        rect.origin.y += textView.textContainerOrigin.y
        let clip = scrollView.contentView
        // Clear of the toolbar and the search capsule at the top, and of the bottom edge.
        let chrome = (window.map { $0.frame.height - $0.contentLayoutRect.height } ?? 52) + NotebookSearch.height + 16
        let comfortable = NSRect(x: clip.bounds.minX, y: clip.bounds.minY + chrome / scrollView.magnification,
                                 width: clip.bounds.width, height: clip.bounds.height - (chrome + 40) / scrollView.magnification)
        if !always, comfortable.contains(rect) { done(); return }
        var origin = NSPoint(x: clip.bounds.minX, y: min(max(0, (rect.minY - clip.bounds.height / 3).rounded()), max(0, textView.frame.height - clip.bounds.height)))
        if rect.minX < clip.bounds.minX || rect.maxX > clip.bounds.maxX {
            origin.x = max(0, min(rect.midX - clip.bounds.width / 2, textView.frame.width - clip.bounds.width))
        }
        // Far away, straight there: years of text flying by say nothing.
        if isFar(origin.y) {
            let third = clip.bounds.height / 3
            land(near: range.location, floor: 0) { [self] in self.rect(at: range.location).map { $0.minY - third } }
            return done()
        }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            camera.stop()
            clip.scroll(to: origin)
            scrollView.reflectScrolledClipView(clip)
            return done()
        }
        camera.move(to: origin, done: done)
    }

    // MARK: - Window

    /// Resizing keeps what you were reading (or writing) where it was.
    private var resizeAnchor: Anchor?
    func windowWillStartLiveResize(_ notification: Notification) { resizeAnchor = readingAnchor() }
    func windowDidEndLiveResize(_ notification: Notification) { resizeAnchor = nil }
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        if !sender.inLiveResize { resizeAnchor = readingAnchor() }
        return frameSize
    }

    func windowDidResize(_ notification: Notification) {
        updateInsets()
        restore(resizeAnchor ?? readingAnchor())
        if window?.inLiveResize != true { resizeAnchor = nil }
    }

    /// In full screen only the writing stays; the toolbar comes down with the menu bar.
    func window(_ window: NSWindow, willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions = []) -> NSApplication.PresentationOptions {
        proposedOptions.union([.fullScreen, .autoHideMenuBar, .autoHideToolbar])
    }

    func windowWillClose(_ notification: Notification) { saveNow(everything: true) }
    func windowDidResignKey(_ notification: Notification) { saveNow() }

    // MARK: - Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.init("index"), .flexibleSpace, .init("search"), .init("reading")]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        item.target = self
        item.isBordered = true
        switch id.rawValue {
        case "index":
            item.label = String(localized: "Index")
            item.toolTip = String(localized: "Index")
            item.image = NSImage(systemSymbolName: "list.bullet", accessibilityDescription: String(localized: "Index"))
            item.action = #selector(showIndex(_:))
        case "search":
            return search.item
        case "reading":
            item.label = String(localized: "Type")
            item.toolTip = String(localized: "Font and Size")
            item.image = NSImage(systemSymbolName: "textformat.size", accessibilityDescription: String(localized: "Font and Size"))
            item.action = #selector(showReading(_:))
        default:
            return nil
        }
        return item
    }

    // MARK: - Debug (QA build, ESSAIS_DEBUG=1)

    #if QA

    func type(_ text: String) { textView.insertText(text, replacementRange: textView.selectedRange()) }

    /// Searches as if typed in the field, for tests (--find).
    func find(_ text: String) {
        showSearch(nil)
        DispatchQueue.main.async { [self] in
            search.item.searchField.stringValue = text
            search.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        }
    }

    /// Puts the caret right after the date line of `day` and types there (--type-at day text).
    func debugTypeAt(_ day: String, _ text: String) -> String {
        guard let body = bodyStart(of: day) else { return "no day" }
        window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: body, length: 0))
        let attrs = textView.typingAttributes
        textView.insertText(text, replacementRange: textView.selectedRange())
        return "typing attrs: dateLine=\(attrs[.dateLine] != nil) day=\(attrs[.day] as? String ?? "nil")"
    }

    /// Caret at the very end of `day`'s text, then forward delete (--delete-after day).
    func debugDeleteAfter(_ day: String) -> String {
        guard let body = bodyStart(of: day) else { return "no day" }
        var end = body
        storage.enumerateAttribute(.day, in: NSRange(location: body, length: storage.length - body)) { v, r, stop in
            if v as? String == day { end = NSMaxRange(r) } else { stop.pointee = true }
        }
        window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: end - 1, length: 0))   // before the "\n" that ends the day
        textView.deleteForward(nil)
        textView.deleteForward(nil)
        let ns = storage.string as NSString
        let line = ns.lineRange(for: NSRange(location: max(0, end - 3), length: 0))
        return "line now: " + ns.substring(with: line).replacingOccurrences(of: "\n", with: "⏎")
    }

    /// Clicks at (x, y) points from the window's top-left and reports the caret (--click x,y;x,y).
    func debugClicks(_ spec: String) -> String {
        guard let window else { return "-" }
        let h = window.contentView!.bounds.height
        return spec.split(separator: ";").map { pair in
            let before = clipTop()
            let focusBefore = String(describing: Swift.type(of: window.firstResponder!))
            let openBefore = search.item.searchField.frame.width > 60
            let n = pair.split(separator: ",").compactMap { Double($0) }
            let p = NSPoint(x: n[0], y: h - n[1])
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                window.sendEvent(e)
            }
            let sel = textView.selectedRange().location
            let day = sel < storage.length ? storage.attribute(.day, at: sel, effectiveRange: nil) as? String ?? "-" : "fin"
            let inDate = sel < storage.length && storage.attribute(.dateLine, at: sel, effectiveRange: nil) != nil
            let field = search.item.searchField
            let open = field.frame.width > 60
            return "foco antes \(focusBefore) búsqueda antes \(openBefore ? "abierta" : "plegada") · papel \(Int(before))→\(Int(clipTop())) búsqueda \(open ? "ABIERTA" : "plegada") (\(Int(n[0])),\(Int(n[1]))) → caret \(sel)/\(storage.length) día \(day)\(inDate ? " DENTRO DE LÍNEA DE FECHA" : "")"
        }.joined(separator: "\n")
    }

    /// Sends key presses to the window as the keyboard would (--keys "53;126;126;36").
    func debugKeys(_ spec: String) -> String {
        guard let window else { return "-" }
        let arrows: [UInt16: Int] = [123: NSLeftArrowFunctionKey, 124: NSRightArrowFunctionKey, 125: NSDownArrowFunctionKey, 126: NSUpArrowFunctionKey,
                                     115: NSHomeFunctionKey, 119: NSEndFunctionKey, 116: NSPageUpFunctionKey, 121: NSPageDownFunctionKey]
        var out: [String] = []
        for item in spec.split(separator: ";") {
            var parts = item.split(separator: ":")[0].split(separator: "+").map(String.init)
            let code = UInt16(parts.removeLast()) ?? 0
            var flags: NSEvent.ModifierFlags = []
            for m in parts { flags.insert(["cmd": .command, "shift": .shift, "opt": .option, "ctrl": .control][m] ?? []) }
            // "0:N" sends key code 0 carrying the text "N": how dictation, emoji and injected text arrive.
            var chars = code == 53 ? "\u{1B}" : code == 36 ? "\r" : code == 51 ? "\u{7F}" : arrows[code].flatMap { UnicodeScalar($0).map { String(Character($0)) } } ?? "x"
            if let colon = item.firstIndex(of: ":") { chars = String(item[item.index(after: colon)...]) }
            let before = clipTop()
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                         isARepeat: false, keyCode: code)!
                NSApp.sendEvent(e)
            }
            let windows = NSApp.windows.filter { $0.isVisible }.count
            out.append("\(item): undo \(textView.undoManager?.canUndo == true ? textView.undoManager!.undoActionName.isEmpty ? "sí" : textView.undoManager!.undoActionName : "no") caret \(textView.selectedRange().location) papel \(Int(before))→\(Int(clipTop())) ventanas \(windows) foco \(String(describing: Swift.type(of: window.firstResponder!)))")
        }
        return out.joined(separator: "\n")
    }

    private func clipTop() -> CGFloat { scrollView.contentView.bounds.minY }

    /// Logs each change of the paper's position: time, y, and whether the camera is driving (--scroll-log).
    func debugScrollLog() {
        var last = scrollView.contentView.bounds.minY
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let y = self.scrollView.contentView.bounds.minY
                guard y != last else { return }
                last = y
                FileHandle.standardError.write(String(format: "scroll %.3f %.1f %@\n", CACurrentMediaTime(), y, self.camera.isMoving ? "camara" : "mano").data(using: .utf8)!)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// The end of the text with its day/date-line runs (kill -USR1 in debug mode).
    func debugTail() -> String {
        let from = max(0, storage.length - 120)
        var out = ["len \(storage.length) caret \(textView.selectedRange()) zoom \(String(format: "%.2f", scrollView.magnification)) clip \(NSStringFromRect(scrollView.contentView.bounds)) papel \(Int(textView.frame.width)) margen \(Int(textView.textContainerInset.width)) docX \(Int(textView.frame.minX))"]
        storage.enumerateAttributes(in: NSRange(location: from, length: storage.length - from)) { attrs, r, _ in
            let t = (storage.string as NSString).substring(with: r).replacingOccurrences(of: "\n", with: "⏎")
            out.append("[\(attrs[.day] as? String ?? "nil")\(attrs[.dateLine] != nil ? " FECHA" : "")] \(t)")
        }
        if let lm = textView.layoutManager, let container = textView.textContainer {
            let clip = scrollView.contentView.bounds, o = textView.textContainerOrigin.y
            let index = { (y: CGFloat) in lm.characterIndexForGlyph(at: lm.glyphIndex(for: NSPoint(x: 1, y: y - o), in: container)) }
            out.append("vista \(index(clip.minY + topBand + 2))…\(index(clip.maxY - 2))")
        }
        var foreign: [String: Int] = [:]
        let others: [NSAttributedString.Key] = [.link, .backgroundColor, .underlineStyle, .strikethroughStyle, .attachment, .shadow, .obliqueness, .baselineOffset]
        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attrs, _, _ in
            for key in others where attrs[key] != nil { foreign[key.rawValue, default: 0] += 1 }
        }
        out.append("atributos ajenos: \(foreign.isEmpty ? "ninguno" : "\(foreign)")")
        out.append("letra \(String(format: "%.0f", lastReadingCost * 1000)) ms, columna \(Int(textView.frame.width - textView.textContainerInset.width * 2))")
        out.append("sin guardar (notas \(dirtyDays.sorted())): \(store.unsaved(days()))")
        out.append("days: " + days().suffix(2).map { "\($0.key)=\($0.text.replacingOccurrences(of: "\n", with: "⏎"))" }.joined(separator: " | "))
        return out.joined(separator: "\n")
    }

    /// Selects from 5 characters into `from` to 5 into `to`, then deletes or types (--cross from,to[,text]).
    func debugCross(_ spec: String) -> String {
        let p = spec.split(separator: ",").map(String.init)
        guard p.count >= 2, let a = bodyStart(of: p[0]), let b = bodyStart(of: p[1]) else { return "no day" }
        window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: a + 5, length: b + 5 - (a + 5)))
        if p.count > 2 { textView.insertText(p[2], replacementRange: textView.selectedRange()) } else { textView.deleteBackward(nil) }
        return "selección borrada/reemplazada"
    }

    /// Moves 12 characters of `from`'s text, with their attributes, to the start of `to` (--drop from,to),
    /// the way drag and drop does inside a text view.
    func debugDrop(_ spec: String) -> String {
        let p = spec.split(separator: ",").map(String.init)
        guard let a = bodyStart(of: p[0]), let b = bodyStart(of: p[1]) else { return "no day" }
        let piece = storage.attributedSubstring(from: NSRange(location: a, length: 12))
        window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: b, length: 0))
        textView.insertText(piece, replacementRange: NSRange(location: b, length: 0))
        return "movido: \(piece.string)"
    }

    /// The items of the right-click menu over the text (--menu).
    func debugMenu() -> String {
        guard let window else { return "-" }
        let e = NSEvent.mouseEvent(with: .rightMouseDown, location: NSPoint(x: 300, y: 300), modifierFlags: [], timestamp: 0,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        return textView.menu(for: e)?.items.map { $0.isSeparatorItem ? "—" : $0.title }.joined(separator: " | ") ?? "sin menú"
    }

    /// Paper width and column before and after a magnification (--zoom-probe 2).
    func debugZoom(_ value: CGFloat) -> String {
        let before = "papel \(Int(textView.frame.width)) margen \(Int(textView.textContainerInset.width))"
        scrollView.magnification = value
        let after = "papel \(Int(textView.frame.width)) margen \(Int(textView.textContainerInset.width))"
        return "antes: \(before) · con \(value)x: \(after) · clip \(Int(scrollView.contentView.bounds.width))"
    }

    /// Which cursor shows over the toolbar, the paper and the search capsule (--cursor-check).
    func debugCursors() -> String {
        guard let window else { return "-" }
        let h = window.contentView!.bounds.height, w = window.contentView!.bounds.width
        let points: [(String, NSPoint)] = [("barra (lupa)", NSPoint(x: w - 60, y: h - 26)), ("barra (vacío)", NSPoint(x: w / 2, y: h - 20)),
                                           ("papel", NSPoint(x: w / 2, y: h / 2))]
        return points.map { name, p in
            let e = NSEvent.mouseEvent(with: .mouseMoved, location: p, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                       context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
            textView.mouseMoved(with: e)
            let c = NSCursor.current
            return "\(name): " + (c == .arrow ? "flecha" : c == .iBeam ? "I" : "otro")
        }.joined(separator: ", ")
    }

    func debugIndexKeys(_ codes: [UInt16]) -> String { indexPopover.debugKeys(codes) }

    /// What VoiceOver's rotors would offer (--rotors).
    func debugRotors() -> String {
        guard let rotors = textView.rotors?.rotors else { return "sin rotores" }
        return rotors.map { rotor in
            var labels: [String] = []
            var current: NSAccessibilityCustomRotor.ItemResult?
            for _ in 0..<20 {
                let p = NSAccessibilityCustomRotor.SearchParameters()
                p.currentItem = current
                p.searchDirection = .next
                guard let r = rotor.itemSearchDelegate?.rotor(rotor, resultFor: p) else { break }
                let at = (storage.string as NSString).substring(with: NSRange(location: r.targetRange.location, length: min(12, storage.length - r.targetRange.location)))
                labels.append("\(r.customLabel ?? "?") @\(r.targetRange.location)+\(r.targetRange.length) «\(at)»")
                current = r
            }
            return "\(rotor.label): " + labels.joined(separator: " | ")
        }.joined(separator: "\n") + "\nselección: \(textView.selectedRange())"
    }

    /// Writes, presses Return and reports the camera's sideways position, at a zoom (--enter-probe 2).
    func debugEnterProbe(_ value: CGFloat) {
        window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: storage.length, length: 0))
        scrollView.magnification = value
        let say = { (t: String) in
            let c = self.scrollView.contentView.bounds
            FileHandle.standardError.write("ENTER \(t): x \(Int(c.minX)) ancho \(Int(c.width)) papel \(Int(self.textView.frame.width)) zoom \(String(format: "%.2f", self.scrollView.magnification))\n".data(using: .utf8)!)
        }
        textView.insertText("Una linea corta", replacementRange: textView.selectedRange())
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            say("escrito")
            self.textView.insertNewline(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                say("tras enter")
                self.textView.insertNewline(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                    say("tras enter 2")
                    self.textView.insertText("otra", replacementRange: self.textView.selectedRange())
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { say("escribe de nuevo") }
                }
            }
        }
    }

    /// Hours of use compressed: types, deletes, undoes, moves around and changes size at random, with
    /// pauses so saves happen. Logs memory, and at the end compares the notebook with the files (--soak min).
    func debugSoak(minutes: Double) {
        func say(_ t: String) { FileHandle.standardError.write(("SOAK " + t + "\n").data(using: .utf8)!) }
        func memory() -> Int {
            var info = task_vm_info_data_t(), count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            let r = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
            return r == KERN_SUCCESS ? Int(info.phys_footprint) / 1_048_576 : -1
        }
        var generator = SemillaSoak(estado: UInt64(QA.env("ESSAIS_SEED") ?? "") ?? 42)
        let words = ["camino", "la", "tarde", "#lectura", "**idea**", "café", "niño", "y", "cuaderno", "# Título", "🙂", "*nota*"]
        let started = Date()
        var actions = 0, lastLog = Date.distantPast, resting = false
        window?.makeFirstResponder(textView)
        NSApp.hide(nil)   // nobody needs to watch the paper jump around
        say("inicio memoria \(memory()) MB, letras \(storage.length)")
        func step() {
            if Date().timeIntervalSince(started) > minutes * 60 {
                saveNow(everything: true)
                let current = days()
                var different = 0
                for day in current where !day.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let disk = store.read(store.directory.appendingPathComponent(day.key + ".md"))
                    if disk != day.text { different += 1; say("DISTINTO \(day.key)") }
                }
                say("fin acciones \(actions), memoria \(memory()) MB, letras \(storage.length), días \(current.count), distintos del disco \(different), sin guardar \(store.unsaved(current).count)")
                say("FIN")
                return
            }
            if Date().timeIntervalSince(lastLog) > 30 { lastLog = Date(); say("t \(Int(Date().timeIntervalSince(started))) s, memoria \(memory()) MB, acciones \(actions), letras \(storage.length)") }
            // Every so often it stops, as a person does, and the save runs.
            if actions % 150 == 149, !resting {
                resting = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { resting = false; actions += 1; step() }
                return
            }
            actions += 1
            let length = storage.length
            let dado = Int.random(in: 0..<100, using: &generator)
            FileHandle.standardError.write("ACC \(actions) dado \(dado) sel \(textView.selectedRange()) largo \(length) undo \(textView.undoManager?.canUndo == true)\n".data(using: .utf8)!)
            switch dado {
            case 0..<50: textView.insertText(words.randomElement(using: &generator)! + " ", replacementRange: textView.selectedRange())
            case 50..<56: textView.insertNewline(nil)
            case 56..<72: textView.deleteBackward(nil)
            // Through the responder chain, as the Edit menu does: asking the undo manager directly skips what
            // the text view does around it, and isn't something a person can do.
            case 72..<76: _ = textView.tryToPerform(Selector(("undo:")), with: nil)
            case 76..<78: _ = textView.tryToPerform(Selector(("redo:")), with: nil)
            case 78..<88: textView.breakUndoCoalescing(); textView.setSelectedRange(NSRange(location: Int.random(in: 0...length, using: &generator), length: 0))
            case 88..<92: textView.breakUndoCoalescing(); textView.setSelectedRange(NSRange(location: length, length: 0))
            case 92..<95:
                let a = Int.random(in: 0...length, using: &generator)
                textView.breakUndoCoalescing()
                textView.setSelectedRange(NSRange(location: a, length: Int.random(in: 0...min(400, length - a), using: &generator)))
                textView.deleteBackward(nil)
            case 95..<97: changeSize(by: Bool.random(using: &generator) ? 1 : -1)
            case 97: zoom(to: CGFloat.random(in: 1...2.5, using: &generator))
            case 98: page(Bool.random(using: &generator) ? 1 : -1)
            default: saveNow()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { step() }
        }
        step()
    }

    /// Frame times of the camera moving and zooming, with the notebook as loaded (--camera-bench).
    func debugCameraBench() {
        var frames: [Bool: [(gap: Double, work: Double)]] = [true: [], false: []]
        var pasos = 0
        PaperCamera.bench = { zooming, gap, work in frames[zooming]?.append((gap, work)) }
        let clip = scrollView.contentView
        func informe() {
            for (nombre, clave) in [("mover", false), ("zoom", true)] {
                let f = (frames[clave] ?? []).dropFirst().filter { $0.gap < 1 }
                guard !f.isEmpty else { continue }
                let g = f.map { $0.gap * 1000 }.sorted(), w = f.map { $0.work * 1000 }.sorted()
                let linea = "\(nombre): \(f.count) cuadros · intervalo p50 \(String(format: "%.1f", g[g.count / 2])) p95 \(String(format: "%.1f", g[g.count * 95 / 100])) max \(String(format: "%.1f", g.last!)) ms · trabajo p50 \(String(format: "%.1f", w[w.count / 2])) p95 \(String(format: "%.1f", w[w.count * 95 / 100])) max \(String(format: "%.1f", w.last!)) ms\n"
                FileHandle.standardError.write(linea.data(using: .utf8)!)
            }
            FileHandle.standardError.write("BENCH FIN\n".data(using: .utf8)!)
        }
        func paso() {
            pasos += 1
            if pasos > 24 { return informe() }
            if pasos <= 12 {
                let base = clip.bounds.minY
                camera.move(to: NSPoint(x: 0, y: pasos % 2 == 0 ? base + 320 : base - 320))
            } else {
                zoom(to: pasos % 2 == 0 ? 2 : 1, around: NSPoint(x: clip.bounds.midX, y: clip.bounds.midY))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { paso() }
        }
        paso()
    }

    /// Walks the text size and reports where the view is after each step (--size-walk reading|writing).
    func debugSizeWalk(_ mode: String) {
        func report(_ note: String) {
            guard let lm = textView.layoutManager, let container = textView.textContainer else { return }
            let clip = scrollView.contentView.bounds, o = textView.textContainerOrigin.y
            let top = lm.characterIndexForGlyph(at: lm.glyphIndex(for: NSPoint(x: 1, y: clip.minY + topBand + 2 - o), in: container))
            let caret = caretRect().map { Int($0.minY - clip.minY) } ?? -1
            let line = "\(note) letra \(Int(Reading.size)) col \(Int(PaperTextView.columnWidth(for: textView.frame.width))) arriba=\(top) (y \(Int((rect(at: top)?.minY ?? 0) - clip.minY))) clip \(Int(clip.minX)),\(Int(clip.minY)) caretY \(caret) mag \(String(format: "%.2f", scrollView.magnification))\n"
            FileHandle.standardError.write(line.data(using: .utf8)!)
        }
        if mode == "reading" {
            let middle = storage.length / 2
            show(NSRange(location: middle, length: 0))
        }
        var steps = Array(repeating: 1, count: 18) + Array(repeating: -1, count: 18)
        func step() {
            report("antes")
            guard !steps.isEmpty else { return }
            changeSize(by: CGFloat(steps.removeFirst()))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { step() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { Reading.size = 13; self.readingChanged(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { step() } }
    }

    /// Shows the first title of the index, for tests (--show-title).
    func showFirstTitle() {
        if let title = NotebookIndex(storage).titles.first { show(title.range) }
    }
    func magnify(_ value: CGFloat) {
        let caret = caretRect().map { NSPoint(x: $0.midX, y: $0.midY) }
        zoom(to: value, around: caret)
    }

    func snapshot(to path: String) {
        guard let view = window?.contentView?.superview, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        // Popovers and the like live in their own windows: one extra file each.
        for (i, other) in NSApp.windows.filter({ $0 !== window && $0.isVisible }).enumerated() {
            guard let v = other.contentView?.superview, let r = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
            v.cacheDisplay(in: v.bounds, to: r)
            try? r.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-\(i + 2).png")))
        }
    }
    #endif
}

#if QA
/// A repeatable sequence, so a failure found by the soak test can be run again.
struct SemillaSoak: RandomNumberGenerator {
    var estado: UInt64
    mutating func next() -> UInt64 {
        estado &+= 0x9E3779B97F4A7C15
        var z = estado
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
#endif

/// The window's content: the paper, and the search capsule floating under the toolbar.
final class PaperContainer: NSView {
    var paper: NSView?
    var navigator: NSView?

    /// The paper fades out under the window's controls instead of passing sharp beneath them.
    private let veil = Veil()

    override func layout() {
        super.layout()
        paper?.frame = bounds
        guard let window else { return }
        let top = window.frame.height - window.contentLayoutRect.height
        if veil.superview == nil, let paper { addSubview(veil, positioned: .above, relativeTo: paper) }
        veil.isHidden = window.styleMask.contains(.fullScreen)   // there the toolbar does its own
        veil.frame = NSRect(x: 0, y: bounds.maxY - top - 14, width: bounds.width, height: top + 14)
        guard let navigator else { return }
        let size = NSSize(width: ((navigator as? NSGlassEffectView)?.contentView?.fittingSize.width ?? 120).rounded(.up), height: NotebookSearch.height)
        navigator.frame = NSRect(x: bounds.maxX - size.width - 14, y: bounds.maxY - top - size.height - 8,
                                 width: size.width, height: size.height).integral
    }
}

/// Paper color at the top, clear at the bottom. Clicks go through to the paper.
final class Veil: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let paper = Paper.sheet
        NSGradient(colorsAndLocations: (paper, 0), (paper, 0.55), (paper.withAlphaComponent(0), 1))?
            .draw(in: bounds, angle: -90)
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}
