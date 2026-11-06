import Foundation

/// Brings the ClearMind journal into the notebook, once: every entry of a day, in order, becomes
/// that day's file. The entries folder is copied to a backup first and never touched afterwards,
/// so the old app keeps working and nothing can be lost.
enum Migration {
    struct Report {
        var days = 0
        var entries = 0
        var skippedEmpty = 0
        var backup: URL?
        /// Per day: letters in the entries vs letters in the new file (whitespace aside).
        var check: [(day: String, before: Int, after: Int)] = []
        var ok: Bool { check.allSatisfy { $0.before == $0.after } }
    }

    /// ~/Documents/ClearMind/.entries, or ESSAIS_ENTRIES.
    static var entries: URL {
        if let custom = QA.env("ESSAIS_ENTRIES") {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return NotebookStore.documents.appendingPathComponent("ClearMind/.entries", isDirectory: true)
    }

    // 2026-10-31-1.md (and iCloud's copies, 2026-10-31-1 2.md); before 2.0: 31-10-26_1.md
    private static let current = try! NSRegularExpression(pattern: #"^(\d{4})-(\d{2})-(\d{2})-(\d+)( \d+)?\.md$"#)
    private static let legacy = try! NSRegularExpression(pattern: #"^(\d{2})-(\d{2})-(\d{2})_(\d+)( \d+)?\.md$"#)
    private static let legacyMarker = "<!-- sealed -->"

    /// Once: into an empty notebook, if there is a journal to bring. Once done (or once the notebook
    /// has days of its own) a mark stays, here and in the folder, which travels to other Macs through
    /// iCloud: emptying the folder later never brings the old journal back.
    static func needed(into store: NotebookStore) -> Bool {
        if UserDefaults.standard.bool(forKey: doneKey) { return false }
        if FileManager.default.fileExists(atPath: store.directory.appendingPathComponent(mark).path) || !store.isEmpty {
            markDone(in: store)
            return false
        }
        return !entryFiles().isEmpty
    }

    private static let doneKey = "broughtClearMind"
    private static let mark = ".essais-clearmind-imported"

    static func markDone(in store: NotebookStore) {
        UserDefaults.standard.set(true, forKey: doneKey)
        let url = store.directory.appendingPathComponent(mark)
        if !FileManager.default.fileExists(atPath: url.path) { try? Data().write(to: url) }
    }

    static func run(into store: NotebookStore) throws -> Report {
        var report = Report()
        report.backup = try backUp()

        var byDay: [String: [(order: [Int], text: String)]] = [:]
        for (name, key, order) in entryFiles() {
            guard let raw = store.read(entries.appendingPathComponent(name)) else { continue }
            let text = body(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            report.entries += 1
            if text.isEmpty { report.skippedEmpty += 1; continue }
            byDay[key, default: []].append((order, text))
        }

        for (key, parts) in byDay.sorted(by: { $0.key < $1.key }) {
            let texts = parts.sorted { $0.order.lexicographicallyPrecedes($1.order) }.map(\.text)
            // Entries of the same day follow each other like paragraphs, as if written in one sitting.
            let day = texts.joined(separator: "\n\n") + "\n"
            guard let date = NotebookStore.date(key) else { continue }
            store.save([Day(key: key, date: date, text: day)])
            let written = store.read(store.directory.appendingPathComponent(key + ".md")) ?? ""
            report.check.append((key, letters(texts.joined()), letters(written)))
            report.days += 1
        }
        return report
    }

    // MARK: -

    /// (file name, day key, order within the day)
    private static func entryFiles() -> [(String, String, [Int])] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: entries.path)) ?? []
        return names.compactMap { name in
            let range = NSRange(name.startIndex..., in: name)
            for (pattern, isLegacy) in [(current, false), (legacy, true)] {
                guard let m = pattern.firstMatch(in: name, range: range) else { continue }
                func int(_ i: Int) -> Int {
                    Range(m.range(at: i), in: name).flatMap { Int(name[$0].trimmingCharacters(in: .whitespaces)) } ?? 0
                }
                let (y, mo, d) = isLegacy ? (2000 + int(3), int(2), int(1)) : (int(1), int(2), int(3))
                return (name, String(format: "%04d-%02d-%02d", y, mo, d), [int(4), int(5)])
            }
            return nil
        }
    }

    /// The text without the `sealed` front matter or the old end marker.
    private static func body(_ raw: String) -> String {
        var body = raw
        if raw.hasPrefix("---\n"), let end = raw.range(of: "\n---\n", range: raw.index(raw.startIndex, offsetBy: 3)..<raw.endIndex) {
            body = String(raw[end.upperBound...])
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix(legacyMarker) { body = String(trimmed.dropLast(legacyMarker.count)) }
        return body
    }

    private static func letters(_ text: String) -> Int {
        text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.count
    }

    /// ~/Library/Application Support/ClearMind/Backups/entries-before-essais-<date>
    private static func backUp() throws -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var folder = support.appendingPathComponent("ClearMind/Backups", isDirectory: true)
        if QA.env("ESSAIS_ENTRIES") != nil {   // tests: next to the test journal
            folder = entries.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let target = folder.appendingPathComponent("entries-before-essais-\(stamp)", isDirectory: true)
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: entries, options: [], error: &coordinationError) { url in
            do { try FileManager.default.copyItem(at: url, to: target) } catch { copyError = error }
        }
        if let error = coordinationError ?? copyError { throw error }
        return target
    }
}
