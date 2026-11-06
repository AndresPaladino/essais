import AppKit

/// Find, the way macOS 26 does it in Finder, Mail and Notes: the toolbar's magnifying glass opens
/// into a search field, every match is tinted in the text, and a small glass capsule counts them.
/// Nothing covers the page and nothing dims it.
@MainActor
final class NotebookSearch: NSObject, NSSearchFieldDelegate {
    let item: NSSearchToolbarItem
    /// "3 of 6  ⌃ ⌄", floating under the toolbar while there is something to find.
    let navigator = NSGlassEffectView()

    private let textView: NSTextView
    private let reveal: (NSRange) -> Void
    private let finish: (NSRange?) -> Void
    private let count = NSTextField(labelWithString: "")
    private let previous = NSButton()
    private let next = NSButton()
    private var matches: [NSRange] = []
    private var current = -1

    static let height: CGFloat = 34

    /// `reveal` scrolls a match into view; `finish` hands the writing back, at the match if any.
    init(identifier: NSToolbarItem.Identifier, textView: NSTextView,
         reveal: @escaping (NSRange) -> Void, finish: @escaping (NSRange?) -> Void) {
        item = NSSearchToolbarItem(itemIdentifier: identifier)
        self.textView = textView
        self.reveal = reveal
        self.finish = finish
        super.init()

        item.label = String(localized: "Search")
        item.toolTip = String(localized: "Search")
        item.preferredWidthForSearchField = 200
        item.resignsFirstResponderWithCancel = true
        let field = item.searchField
        field.placeholderString = String(localized: "Search")
        field.delegate = self
        field.sendsSearchStringImmediately = true
        field.recentsAutosaveName = nil
        // The glass capsule already shows where you are typing; the blue ring only adds noise.
        field.focusRingType = .none
        // Narrow when idle, so the item rests as a magnifying glass and AppKit stretches it to
        // preferredWidthForSearchField when searching, then folds it back.
        let idle = field.widthAnchor.constraint(lessThanOrEqualToConstant: 30)
        idle.priority = .init(700)
        idle.isActive = true

        count.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        count.textColor = .secondaryLabelColor
        for (button, symbol, label, action) in [(previous, "chevron.up", String(localized: "Previous"), #selector(showPrevious(_:))),
                                                (next, "chevron.down", String(localized: "Next"), #selector(showNext(_:)))] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
            button.isBordered = false
            button.target = self
            button.action = action
            button.toolTip = label
        }
        let stack = NSStackView(views: [count, previous, next])
        stack.spacing = 10
        stack.setCustomSpacing(14, after: count)
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 12)
        navigator.contentView = stack
        navigator.cornerRadius = Self.height / 2
        navigator.isHidden = true
        navigator.setAccessibilityElement(true)
        navigator.setAccessibilityRole(.group)
    }

    var isActive: Bool { !query.isEmpty }
    private var query: String { item.searchField.stringValue }

    // MARK: - Actions

    /// ⌘F: opens the field, with the selection as the query when there is one.
    /// Whether the field is out (expanded). Asking AppKit to begin a search that is already open
    /// left the item unable to fold back: ⌘F twice, then Escape, and the field stayed open.
    private var open = false

    /// ⌘F: opens the field; if it is already open, selects what's in it, as Safari and Notes do.
    func begin() {
        if open {
            // Still unfolding: it's on its way, leave it be. Already in the field: select its text.
            item.searchField.currentEditor()?.selectAll(nil)
            return
        }
        open = true
        item.beginSearchInteraction()
    }

    private func fold() {
        guard open else { return }
        open = false
        item.endSearchInteraction()
    }

    /// ⌘E
    func useSelection() {
        let selected = textView.selectedRange()
        guard selected.length > 0 else { return }
        item.searchField.stringValue = (textView.string as NSString).substring(with: selected)
        search(from: selected.location)
    }

    /// Fills the field and goes to the last match (a tag from the index: its most recent use).
    func look(for text: String) {
        item.searchField.stringValue = text
        search(from: (textView.string as NSString).length)
    }

    @objc func showNext(_ sender: Any?) { step(1) }
    @objc func showPrevious(_ sender: Any?) { step(-1) }

    /// Escape: matches go away and the caret lands on the one you were looking at.
    func end() {
        let match = matches.indices.contains(current) ? matches[current] : nil
        item.searchField.stringValue = ""
        clear()
        finish(match)   // the caret goes to the match before the text takes the focus back
        fold()
    }

    /// The text changed under the search: recount, keep the place.
    /// Waits for a pause in the typing: in years of writing a search isn't free.
    func refresh() {
        guard isActive else { return }
        later(0.4) { [weak self] in
            guard let self, self.isActive else { return }
            let at = self.matches.indices.contains(self.current) ? self.matches[self.current].location : self.textView.selectedRange().location
            self.find()
            self.current = self.matches.isEmpty ? -1 : (self.matches.firstIndex { $0.location >= at } ?? self.matches.count - 1)
            self.paint(announce: false)
        }
    }

    private var pending: DispatchWorkItem?
    private func later(_ delay: Double, _ work: @escaping () -> Void) {
        pending?.cancel()
        let item = DispatchWorkItem(block: work)
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    // MARK: - Search field

    func controlTextDidChange(_ obj: Notification) {
        let from = firstVisibleCharacter()
        later(0.15) { [weak self] in self?.search(from: from) }
    }

    func searchFieldDidEndSearching(_ sender: NSSearchField) {
        if sender.stringValue.isEmpty { clear() }
    }

    /// Back in the text with an empty field: the field folds back into the magnifying glass. With
    /// a query the field and its matches stay until Escape. (controlTextDidEndEditing isn't sent
    /// when nothing was typed, so the text view tells us.)
    func textTookFocus() {
        if query.isEmpty { fold() }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            step(NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? -1 : 1)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            end()
            return true
        default:
            return false
        }
    }

    // MARK: - Matching

    private func search(from location: Int) {
        find()
        // From what's on screen on; nothing after it, the closest before it (in a diary, what you're
        // looking for is more likely yesterday than five years ago).
        current = matches.isEmpty ? -1 : (matches.firstIndex { $0.location >= location } ?? matches.count - 1)
        paint()
        if current >= 0 { reveal(matches[current]) }
    }

    private func step(_ delta: Int) {
        guard !matches.isEmpty else { NSSound.beep(); return }
        current = (current + delta + matches.count) % matches.count
        paint()
        reveal(matches[current])
    }

    /// Ignores case and accents, so "aristoteles" finds "Aristóteles".
    private func find() {
        matches = []
        let text = textView.string as NSString
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return }
        var range = NSRange(location: 0, length: text.length)
        while range.length > 0 {
            let found = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive], range: range)
            guard found.location != NSNotFound else { break }
            // The dates are the page's, not your writing: "noviembre" finds what you wrote about it.
            if textView.textStorage?.attribute(.dateLine, at: found.location, effectiveRange: nil) == nil { matches.append(found) }
            range = NSRange(location: NSMaxRange(found), length: text.length - NSMaxRange(found))
        }
    }

    private func firstVisibleCharacter() -> Int {
        guard let lm = textView.layoutManager, let container = textView.textContainer else { return 0 }
        var point = textView.visibleRect.origin
        point.y -= textView.textContainerOrigin.y
        point.x = 0
        let glyph = lm.glyphIndex(for: point, in: container)
        return lm.characterIndexForGlyph(at: glyph)
    }

    // MARK: - Drawing

    /// Temporary attributes: tinted, not part of the text, never saved, no relayout.
    private func paint(announce: Bool = true) {
        guard let lm = textView.layoutManager else { return }
        let all = NSRange(location: 0, length: (textView.string as NSString).length)
        lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: all)
        lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: all)
        let soft = NSColor.findHighlightColor.withAlphaComponent(0.35)
        // Thousands of matches: only those around the current one are painted (the rest are far away).
        let center = matches.indices.contains(current) ? matches[current].location : 0
        for (i, m) in matches.enumerated() where matches.count < 500 || abs(m.location - center) < 40_000 {
            lm.addTemporaryAttribute(.backgroundColor, value: i == current ? NSColor.findHighlightColor : soft, forCharacterRange: m)
        }
        // The current match is dark on yellow in both appearances (white on yellow can't be read).
        if matches.indices.contains(current) {
            lm.addTemporaryAttribute(.foregroundColor, value: NSColor.black, forCharacterRange: matches[current])
        }

        navigator.isHidden = !isActive
        let enabled = matches.count > 1
        previous.isEnabled = enabled
        next.isEnabled = enabled
        count.stringValue = matches.isEmpty ? String(localized: "No Results") : String(localized: "\(current + 1) of \(matches.count)")
        navigator.setAccessibilityLabel(count.stringValue)
        if announce { NSAccessibility.post(element: navigator, notification: .announcementRequested,
                             userInfo: [.announcement: count.stringValue, .priority: NSAccessibilityPriorityLevel.medium.rawValue]) }
        navigator.superview?.needsLayout = true
    }

    private func clear() {
        matches = []
        current = -1
        if let lm = textView.layoutManager {
            let all = NSRange(location: 0, length: (textView.string as NSString).length)
            lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: all)
            lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: all)
        }
        navigator.isHidden = true
    }
}
