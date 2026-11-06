import AppKit

/// VoiceOver rotors for the notebook, like headings in Pages: Days walks the date lines,
/// Titles the `# titles`. With them a long notebook can be crossed without reading it all.
@MainActor
final class NotebookRotors: NSObject, NSAccessibilityCustomRotorItemSearchDelegate {
    private weak var textView: NSTextView?

    init(textView: NSTextView) {
        self.textView = textView
        super.init()
        // The lists are built once and kept until the text changes: VoiceOver asks item by item,
        // and rebuilding years of days for every step froze the app.
        NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: textView.textStorage, queue: nil) { [weak self] note in
            guard let storage = note.object as? NSTextStorage, storage.editedMask.contains(.editedCharacters) else { return }
            MainActor.assumeIsolated { self?.cache = [:] }
        }
    }

    private var cache: [ObjectIdentifier: [(range: NSRange, label: String)]] = [:]

    private func items(for rotor: NSAccessibilityCustomRotor, in storage: NSTextStorage) -> [(range: NSRange, label: String)] {
        if let cached = cache[ObjectIdentifier(rotor)] { return cached }
        let built = rotor === rotors.first ? days(storage) : titles(storage)
        cache[ObjectIdentifier(rotor)] = built
        return built
    }

    lazy var rotors: [NSAccessibilityCustomRotor] = [
        NSAccessibilityCustomRotor(label: String(localized: "Days"), itemSearchDelegate: self),
        NSAccessibilityCustomRotor(label: String(localized: "Titles"), itemSearchDelegate: self),
    ]

    nonisolated func rotor(_ rotor: NSAccessibilityCustomRotor,
                           resultFor search: NSAccessibilityCustomRotor.SearchParameters) -> NSAccessibilityCustomRotor.ItemResult? {
        nonisolated(unsafe) var found: NSAccessibilityCustomRotor.ItemResult?
        MainActor.assumeIsolated {
            guard let textView, let storage = textView.textStorage else { return }
            let items = items(for: rotor, in: storage)
            let from = search.currentItem?.targetRange.location ?? (search.searchDirection == .next ? -1 : Int.max)
            let match = search.searchDirection == .next ? items.first { $0.range.location > from }
                                                        : items.last { $0.range.location < from }
            guard let match else { return }
            let result = NSAccessibilityCustomRotor.ItemResult(targetElement: textView)
            result.targetRange = match.range
            result.customLabel = match.label
            found = result
        }
        return found
    }

    private func days(_ storage: NSTextStorage) -> [(range: NSRange, label: String)] {
        var items: [(NSRange, String)] = []
        storage.enumerateAttribute(.dateLine, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard value != nil, let day = storage.attribute(.day, at: range.location, effectiveRange: nil) as? String else { return }
            items.append((range, NotebookIndex.longDate(day)))
        }
        return items
    }

    private func titles(_ storage: NSTextStorage) -> [(range: NSRange, label: String)] {
        NotebookIndex(storage).titles.map { ($0.range, $0.text) }
    }
}
