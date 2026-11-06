import AppKit

/// Locke's commonplace index, built from the text itself: `# titles` and `#tags`, each with
/// the day it appears. Nothing to maintain; references are dates, which never move.
struct NotebookIndex {
    struct Title { let text: String; let range: NSRange; let day: String }
    /// A tag and the days it appears on (a tag used twice in a day counts one day).
    struct Tag { let name: String; var days: Set<String> }

    var titles: [Title] = []
    var tags: [Tag] = []

    private static let heading = try! NSRegularExpression(pattern: #"^#{1,3}[ \t]+(.+)$"#)

    init() {}

    init(_ text: NSAttributedString) {
        let ns = text.string as NSString
        var byTag: [String: Tag] = [:]
        var titles: [Title] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byParagraphs]) { line, range, _, _ in
            guard let line, range.length > 0, text.attribute(.dateLine, at: range.location, effectiveRange: nil) == nil,
                  let day = text.attribute(.day, at: range.location, effectiveRange: nil) as? String else { return }
            let whole = NSRange(location: 0, length: (line as NSString).length)
            if let m = Self.heading.firstMatch(in: line, range: whole) {
                let title = (line as NSString).substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
                titles.append(Title(text: title, range: range, day: day))
            }
            for m in Markdown.tag.matches(in: line, range: whole) {
                // The same tag whether its accents came composed or not (text pasted from a PDF).
                let name = (line as NSString).substring(with: m.range(at: 1)).precomposedStringWithCanonicalMapping.lowercased()
                byTag[name, default: Tag(name: name, days: [])].days.insert(day)
            }
        }
        self.titles = titles
        tags = byTag.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func shortDate(_ day: String) -> String {
        guard let date = NotebookStore.date(day) else { return day }
        return Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
            ? date.formatted(.dateTime.day().month(.abbreviated))
            : date.formatted(.dateTime.day().month(.abbreviated).year())
    }

    /// In a section of its year: "4 Nov".
    static func dayAndMonth(_ day: String) -> String {
        NotebookStore.date(day)?.formatted(.dateTime.day().month(.abbreviated)) ?? day
    }

    /// For VoiceOver: "Wednesday, November 4", with the year when it isn't this one.
    static func longDate(_ day: String) -> String {
        guard let date = NotebookStore.date(day) else { return day }
        let thisYear = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
        return thisYear ? date.formatted(.dateTime.weekday(.wide).day().month(.wide))
                        : date.formatted(.dateTime.day().month(.wide).year())
    }
}

/// The index as a popover from the toolbar, like the table of contents in Books: Titles and Tags
/// in two tabs, the most recent first, by year. A list you can read with VoiceOver and walk with the
/// keyboard: ↑↓ move, ←→ change tabs, ↩ goes. When it doesn't fit, typing filters it.
@MainActor
final class IndexPopover: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSPopoverDelegate, NSSearchFieldDelegate {
    private enum Row {
        case header(String)
        case note(String)
        case title(NotebookIndex.Title, showsYear: Bool)
        case tag(NotebookIndex.Tag)
    }
    private enum Tab: Int { case titles, tags }

    private static let width: CGFloat = 340
    private static let maxHeight: CGFloat = 460

    private let popover = NSPopover()
    private let onTitle: (NSRange) -> Void
    private let onTag: (String) -> Void
    private var index = NotebookIndex()
    private var rows: [Row] = []
    private var tab = Tab.titles
    private var filter = ""
    private var table: IndexTable?
    private var field: NSSearchField?
    private var tabs: NSSegmentedControl?

    /// `onTitle` goes to a title; `onTag` searches a tag's every appearance.
    init(onTitle: @escaping (NSRange) -> Void, onTag: @escaping (String) -> Void) {
        self.onTitle = onTitle
        self.onTag = onTag
        super.init()
        popover.behavior = .transient
        popover.delegate = self
    }

    var isShown: Bool { popover.isShown }
    /// A click on the popover's own toolbar button must not close it as "a click outside": the
    /// button closes it instantly instead. Otherwise the click started a fade-out, the button then
    /// saw it still shown, and the next clicks fell into that gap.
    private weak var anchor: NSToolbarItem?
    private var closing = false
    func popoverShouldClose(_ popover: NSPopover) -> Bool { !clickIsOn(anchor, NSApp.currentEvent) }
    func popoverWillClose(_ notification: Notification) { closing = true }
    func popoverDidClose(_ notification: Notification) { closing = false }
    private var resignObserver: NSObjectProtocol?

    func close() {
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        guard popover.isShown else { return }
        popover.animates = false
        popover.close()
        popover.animates = true
    }

    func toggle(from item: NSToolbarItem, index: NotebookIndex) {
        // Closing never animates: pressed again while it fades, the popover still counted as shown,
        // so the next press "closed" it again and seemed ignored. Opening keeps its animation.
        anchor = item
        if popover.isShown, !closing { close(); return }
        // Still fading out after a click elsewhere: showing again takes it back.
        self.index = index
        popover.contentViewController = content()
        popover.show(relativeTo: item)
        // Transient popovers close on a click elsewhere, not when the keyboard goes elsewhere (⌘F):
        // then the list stayed open with a dark, inactive selection.
        if let window = table?.window {
            resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            }
        }
        // Nothing is selected until you ask: an accent-colored row isn't how a calm list opens.
        table?.window?.makeFirstResponder(field ?? table)
    }

    // MARK: - Content

    private func buildRows() {
        rows = []
        let matches = { (text: String) in self.filter.isEmpty || text.range(of: self.filter, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        switch tab {
        case .tags:
            rows = index.tags.filter { matches($0.name) || matches("#" + $0.name) }.map { .tag($0) }
        case .titles:
            let titles = index.titles.filter { matches($0.text) }.reversed() as [NotebookIndex.Title]
            let thisYear = String(Calendar(identifier: .gregorian).component(.year, from: Date()))
            let years = Set(titles.map { String($0.day.prefix(4)) })
            // By year only when there's more than one to tell apart; the year then needn't repeat.
            if years.count > 1 || (years.first.map { $0 != thisYear } ?? false) {
                var year = ""
                for title in titles {
                    if title.day.prefix(4) != year {
                        year = String(title.day.prefix(4))
                        rows.append(.header(year))
                    }
                    rows.append(.title(title, showsYear: false))
                }
            } else {
                rows = titles.map { .title($0, showsYear: false) }
            }
        }
        if rows.isEmpty {
            rows = [.note(filter.isEmpty
                ? String(localized: "Start a line with # and a title, or write a #tag anywhere, and it will appear here.")
                : String(localized: "No Results"))]
        }
    }

    private func content() -> NSViewController {
        filter = ""
        // Back to the tab it was on, unless that one has nothing.
        if tab == .titles, index.titles.isEmpty, !index.tags.isEmpty { tab = .tags }
        if tab == .tags, index.tags.isEmpty { tab = .titles }

        let table = IndexTable()
        table.addTableColumn(NSTableColumn(identifier: .init("index")))
        table.headerView = nil
        table.style = .inset
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.floatsGroupRows = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked(_:))
        table.onActivate = { [weak self] row in self?.go(row) }
        table.onSwitchTab = { [weak self] in self?.switchTab() }
        table.setAccessibilityLabel(String(localized: "Index"))
        self.table = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        scroll.automaticallyAdjustsContentInsets = false

        // Measure the real lists (the inset style adds its own spacing) instead of guessing. The height
        // is the taller tab's, so changing tabs or filtering doesn't move the popover.
        scroll.frame = NSRect(x: 0, y: 0, width: Self.width, height: 2000)
        let current = tab
        for each in [Tab.titles, .tags] {
            tab = each
            buildRows()
            table.reloadData()
            scroll.layoutSubtreeIfNeeded()
            heights[each] = table.rect(ofRow: rows.count - 1).maxY + 12
        }
        let listHeight = heights.values.max() ?? 0
        tab = current
        buildRows()
        table.reloadData()

        // The controls earn their place: tabs when both lists exist, the filter when a list doesn't fit.
        var controls: [NSView] = []
        tabs = nil
        if !index.titles.isEmpty, !index.tags.isEmpty {
            let tabs = NSSegmentedControl(labels: [String(localized: "Titles"), String(localized: "Tags")], trackingMode: .selectOne, target: self, action: #selector(tabChanged(_:)))
            tabs.segmentDistribution = .fillEqually
            tabs.selectedSegment = tab.rawValue
            tabs.setAccessibilityLabel(String(localized: "Index"))
            self.tabs = tabs
            controls.append(tabs)
        }
        field = nil
        if listHeight > Self.maxHeight {
            let field = NSSearchField()
            field.placeholderString = String(localized: "Filter")
            field.focusRingType = .none
            field.sendsSearchStringImmediately = true
            field.delegate = self
            self.field = field
            controls.append(field)
        }

        let root = NSView()
        var top = root.topAnchor
        var inset: CGFloat = 14
        var constraints: [NSLayoutConstraint] = []
        for control in controls {
            control.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(control)
            constraints += [control.topAnchor.constraint(equalTo: top, constant: inset),
                            control.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
                            control.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14)]
            top = control.bottomAnchor
            inset = 8
        }
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)
        constraints += [scroll.topAnchor.constraint(equalTo: top, constant: controls.isEmpty ? 0 : 6),
                        scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                        scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                        scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor)]
        NSLayoutConstraint.activate(constraints)
        controlsHeight = controls.reduce(CGFloat(controls.isEmpty ? 0 : 20)) { $0 + $1.fittingSize.height + 8 }

        let controller = NSViewController()
        controller.view = root
        controller.preferredContentSize = NSSize(width: Self.width, height: height(of: tab))
        return controller
    }

    /// As tall as its list. With a filter the list is long and the height stays put while you type.
    private var heights: [Tab: CGFloat] = [:]
    private var controlsHeight: CGFloat = 0
    private func height(of tab: Tab) -> CGFloat {
        min(((field == nil ? heights[tab] : heights.values.max()) ?? 0) + controlsHeight, Self.maxHeight)
    }

    private func reload() {
        buildRows()
        table?.reloadData()
        table?.scrollRowToVisible(0)
    }

    @objc private func tabChanged(_ sender: NSSegmentedControl) {
        tab = Tab(rawValue: sender.selectedSegment) ?? .titles
        reload()
        // Through the controller, which also resizes its view: the popover's own contentSize grew the
        // window around a view of the old size, pinned to the bottom, and left a gap on top.
        popover.contentViewController?.preferredContentSize = NSSize(width: Self.width, height: height(of: tab))
    }

    private func switchTab() {
        guard let tabs else { NSSound.beep(); return }
        tabs.selectedSegment = tabs.selectedSegment == 0 ? 1 : 0
        tabChanged(tabs)
    }

    // MARK: - Filter

    func controlTextDidChange(_ obj: Notification) {
        filter = field?.stringValue.trimmingCharacters(in: .whitespaces) ?? ""
        reload()
        // Typing narrows it down; ↩ goes to the first of what's left.
        if !filter.isEmpty, let first = rows.indices.first(where: { isSelectable($0) }) {
            table?.selectRowIndexes([first], byExtendingSelection: false)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): moveSelection(1); return true
        case #selector(NSResponder.moveUp(_:)): moveSelection(-1); return true
        case #selector(NSResponder.insertNewline(_:)):
            if let row = table?.selectedRow, row >= 0 { go(row) }
            return true
        case #selector(NSResponder.moveLeft(_:)), #selector(NSResponder.moveRight(_:)):
            guard textView.string.isEmpty else { return false }
            switchTab()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            if textView.string.isEmpty { close(); return true }
            return false
        default:
            return false
        }
    }

    private func moveSelection(_ delta: Int) {
        guard let table else { return }
        var row = table.selectedRow < 0 && delta < 0 ? rows.count : table.selectedRow
        repeat { row += delta } while rows.indices.contains(row) && !isSelectable(row)
        guard rows.indices.contains(row) else { return }
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { isSelectable(row) }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .header: return 30
        case .note: return 54
        default: return 28
        }
    }

    /// Without a filter, typing a few letters jumps to the row that starts with them.
    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        switch rows[row] {
        case .title(let title, _): return title.text
        case .tag(let tag): return tag.name
        default: return nil
        }
    }

    private func isSelectable(_ row: Int) -> Bool {
        switch rows[row] {
        case .title, .tag: return true
        default: return false
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = IndexCell()
        var views: [NSView]
        switch rows[row] {
        case .header(let title):
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            label.setAccessibilityRole(.staticText)
            label.setAccessibilityLabel(title)
            views = [label]
        case .note(let text):
            let label = NSTextField(wrappingLabelWithString: text)
            label.textColor = .secondaryLabelColor
            label.font = .systemFont(ofSize: 13)
            label.preferredMaxLayoutWidth = Self.width - 32
            views = [label]
        case .title(let title, let showsYear):
            let label = rowLabel(title.text)
            let date = quietLabel(showsYear ? NotebookIndex.shortDate(title.day) : NotebookIndex.dayAndMonth(title.day))
            cell.quiet = [date]
            views = [label, flexible(), date]
            cell.setAccessibilityElement(true)
            cell.setAccessibilityRole(.staticText)
            cell.setAccessibilityLabel("\(title.text), \(NotebookIndex.longDate(title.day))")
        case .tag(let tag):
            let label = rowLabel("#" + tag.name)
            let count = quietLabel(String(tag.days.count))
            cell.quiet = [count]
            views = [label, flexible(), count]
            cell.setAccessibilityElement(true)
            cell.setAccessibilityRole(.staticText)
            cell.setAccessibilityLabel(tag.days.count == 1
                ? String(localized: "Tag \(tag.name), one day")
                : String(localized: "Tag \(tag.name), \(tag.days.count) days"))
        }
        let stack = NSStackView(views: views)
        stack.distribution = .fill
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    // MARK: - Going somewhere

    @objc private func clicked(_ sender: NSTableView) {
        if sender.clickedRow >= 0 { go(sender.clickedRow) }
    }

    private func go(_ row: Int) {
        guard rows.indices.contains(row) else { return }
        switch rows[row] {
        case .title(let title, _): close(); onTitle(title.range)
        case .tag(let tag): close(); onTag("#" + tag.name)
        default: break
        }
    }

    #if QA
    /// Tests (--index-keys): presses keys in the list and describes what VoiceOver would hear.
    func debugKeys(_ codes: [UInt16]) -> String {
        guard let table, let window = table.window else { return "sin tabla" }
        var out: [String] = []
        for code in codes {
            let arrows: [UInt16: Int] = [123: NSLeftArrowFunctionKey, 124: NSRightArrowFunctionKey, 125: NSDownArrowFunctionKey, 126: NSUpArrowFunctionKey]
            let chars = code == 36 ? "\r" : arrows[code].flatMap { UnicodeScalar($0).map { String(Character($0)) } } ?? " "
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                        context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
                window.firstResponder?.keyDown(with: e)
            }
            let row = table.selectedRow
            let label = row >= 0 ? (table.view(atColumn: 0, row: row, makeIfNecessary: false)?.accessibilityLabel() ?? "-") : "-"
            out.append("key \(code) → fila \(row) de \(rows.count): \(label)")
        }
        return out.joined(separator: "\n")
    }
    #endif

    // MARK: - Pieces

    private func rowLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    private func quietLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        return label
    }

    private func flexible() -> NSView {
        let v = NSView()
        v.setContentHuggingPriority(.init(1), for: .horizontal)
        return v
    }
}

/// A row of the index. Quiet text follows the selection: white on the accent color.
private final class IndexCell: NSTableCellView {
    var quiet: [NSTextField] = []

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            let selected = backgroundStyle == .emphasized
            for label in quiet {
                label.textColor = selected ? .alternateSelectedControlTextColor.withAlphaComponent(0.75) : .secondaryLabelColor
            }
        }
    }
}

/// ↩ goes to the selected row; ←→ change tabs.
private final class IndexTable: NSTableView {
    var onActivate: ((Int) -> Void)?
    var onSwitchTab: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: if selectedRow >= 0 { onActivate?(selectedRow) }   // return, enter
        case 123, 124: onSwitchTab?()                                    // left, right
        default: super.keyDown(with: event)
        }
    }
}

/// Whether a mouse-down landed on a given toolbar item's button (found by hit-testing the window
/// frame and matching the item's tool tip up the view chain).
@MainActor
func clickIsOn(_ item: NSToolbarItem?, _ event: NSEvent?) -> Bool {
    guard let item, let event, event.type == .leftMouseDown, let frame = event.window?.contentView?.superview else { return false }
    var view = frame.hitTest(event.locationInWindow)
    while let v = view {
        if v.toolTip == item.toolTip || v.accessibilityLabel() == item.label { return true }
        view = v.superview
    }
    return false
}
