import AppKit

/// What belongs to the notebook in a folder. Only these files ever move: a folder chosen for the
/// notebook can hold anything else, and that stays where it is.
enum NotebookFiles {
    /// A day (`2026-11-06.md`), a copy of one (`2026-11-06 (otra versión).md`, iCloud's `2026-11-06 2.md`).
    private static let dayOrCopy = try! NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}( .*)?\.md$"#)
    private static let day = try! NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}\.md$"#)
    static let mark = ".essais-clearmind-imported"

    private static func matches(_ rule: NSRegularExpression, _ name: String) -> Bool {
        rule.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }

    static func isDay(_ name: String) -> Bool { matches(day, name) }

    /// The notebook's files by their real names. A file iCloud has evicted can appear as
    /// `.2026-11-06.md.icloud`; asking for its real name downloads it.
    static func names(in folder: URL) -> [String] {
        let all = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var names = Set<String>()
        for name in all {
            var real = name
            if name.hasPrefix("."), name.hasSuffix(".icloud") { real = String(name.dropFirst().dropLast(7)) }
            if real == mark || matches(dayOrCopy, real) { names.insert(real) }
        }
        return names.sorted()
    }

    static func read(_ url: URL) throws -> Data {
        var data: Data?
        var failure: Error?
        var coordination: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordination) { url in
            do { data = try Data(contentsOf: url) } catch { failure = error }
        }
        if let error = coordination ?? failure { throw error }
        guard let data else { throw CocoaError(.fileReadUnknown) }
        return data
    }

    /// "Documentos/Essais": a folder as people know it, not as a path.
    static func label(for folder: URL) -> String {
        let files = FileManager.default
        let parent = folder.deletingLastPathComponent()
        return files.displayName(atPath: parent.path) + "/" + files.displayName(atPath: folder.path)
    }

    /// Where a move takes the notebook, in the words of whoever reads it: "Essais" alone says nothing.
    static func place(of folder: URL) -> String {
        let shown = folder.lastPathComponent == "Essais" ? folder.deletingLastPathComponent() : folder
        return FileManager.default.displayName(atPath: shown.path)
    }

    /// A chosen folder that is already a notebook is used as it is; any other gets an Essais folder inside.
    static func destination(for chosen: URL) -> URL {
        let folder = chosen.standardizedFileURL
        if folder.lastPathComponent == "Essais" || names(in: folder).contains(where: isDay) { return folder }
        return folder.appendingPathComponent("Essais", isDirectory: true)
    }

    static func isInICloud(_ folder: URL) -> Bool {
        var probe = folder
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 { probe = probe.deletingLastPathComponent() }
        return (try? probe.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem ?? false
    }
}

/// Takes the notebook to another folder. Everything is copied and compared before anything is
/// replaced, and the original goes to the Trash only once the notebook is open in its new place.
/// If any step fails, the notebook stays where it was, untouched.
@MainActor
final class NotebookMover {
    private let notebook: NotebookController
    private let store: NotebookStore

    init(notebook: NotebookController, store: NotebookStore) {
        self.notebook = notebook
        self.store = store
    }

    /// What the two folders hold.
    private struct Survey: Sendable {
        var names: [String]
        var days: Int
        var daysThere: Int
        var different: Int
    }

    private enum Choice { case move, useOnly, cancel }

    func chooseFolder(from window: NSWindow) async -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Choose a folder for the notebook.")
        panel.directoryURL = store.directory.deletingLastPathComponent()
        guard await panel.beginSheetModal(for: window) == .OK, let chosen = panel.url else { return false }
        return await move(to: NotebookFiles.destination(for: chosen), from: window)
    }

    /// True if the notebook is now in `destination`.
    @discardableResult
    func move(to destination: URL, from window: NSWindow) async -> Bool {
        let source = store.directory.standardizedFileURL
        let target = destination.standardizedFileURL
        guard source.path != target.path else { return true }
        if (target.path + "/").hasPrefix(source.path + "/") || (source.path + "/").hasPrefix(target.path + "/") {
            await say(String(localized: "This folder can’t be used"), String(localized: "Choose a folder outside the current notebook folder."), on: window)
            return false
        }
        // Nothing can be written while the notebook is on its way, and all of it is on disk first.
        notebook.setWritingPaused(true)
        defer { notebook.setWritingPaused(false) }
        guard notebook.saveNow(everything: true).failed.isEmpty else {
            await say(String(localized: "The notebook couldn’t be moved"), String(localized: "The notebook stays in its current location."), on: window)
            return false
        }

        let survey: Survey
        do { survey = try await Self.inBackground { try Self.survey(source, target) } }
        catch {
            await say(String(localized: "The notebook couldn’t be moved"), String(localized: "The notebook stays in its current location."), on: window)
            return false
        }

        // An empty notebook has nothing to move: it opens in the new place, with what's there.
        guard survey.days > 0 else {
            guard Self.prepare(target) else {
                await say(String(localized: "This folder can’t be used"), String(localized: "Essais doesn’t have permission to save there."), on: window)
                return false
            }
            notebook.openFolder(target)
            return true
        }

        switch await ask(survey, source: source, target: target, on: window) {
        case .cancel:
            return false
        case .useOnly:
            notebook.openFolder(target)
            return true
        case .move:
            break
        }

        let progress = MoveProgress(total: survey.names.count)
        window.beginSheet(progress.window, completionHandler: nil)
        let names = survey.names
        do {
            try await Self.inBackground {
                try Self.transfer(names, from: source, to: target) { done in
                    DispatchQueue.main.async { MainActor.assumeIsolated { progress.update(done) } }
                }
            }
        } catch {
            NSLog("Essais: couldn't move the notebook: %@", String(describing: error))
            window.endSheet(progress.window)
            await say(String(localized: "The notebook couldn’t be moved"), String(localized: "The notebook stays in its current location."), on: window)
            return false
        }
        notebook.openFolder(target)
        // The notebook is safe in its new place and open for writing: the rest happens behind it.
        window.endSheet(progress.window)
        notebook.setWritingPaused(false)
        // If the old one can't go to the Trash, it just stays.
        let trashed = await Self.inBackground { Self.trashOriginal(names, in: source) }
        if !trashed {
            let alert = NSAlert()
            alert.messageText = String(localized: "The previous folder couldn’t be moved to the Trash")
            alert.informativeText = String(localized: "The notebook is already in its new location. The previous folder can be deleted.")
            alert.addButton(withTitle: String(localized: "OK"))
            alert.addButton(withTitle: String(localized: "Show in Finder"))
            if await alert.beginSheetModal(for: window) == .alertSecondButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting([source])
            }
        }
        return true
    }

    private func ask(_ survey: Survey, source: URL, target: URL, on window: NSWindow) async -> Choice {
        let alert = NSAlert()
        let name = NotebookFiles.label(for: target)
        if survey.daysThere == 0 {
            alert.messageText = String(localized: "Move the notebook to \(name)?")
            var text = String(localized: "The notebook (\(Self.count(survey.days))) will move from \(NotebookFiles.place(of: source)) to \(NotebookFiles.place(of: target)). If this can’t be completed, the notebook stays in its current location.")
            if NotebookFiles.isInICloud(source), !NotebookFiles.isInICloud(target) {
                text += "\n\n" + String(localized: "This folder isn’t in iCloud Drive, so the notebook will stop syncing with iCloud.")
            }
            alert.informativeText = text
            alert.addButton(withTitle: String(localized: "Move"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn ? .move : .cancel
        }
        alert.messageText = String(localized: "\(name) already has \(Self.count(survey.daysThere))")
        alert.informativeText = survey.different > 0
            ? String(localized: "Days with different text in the two locations: \(survey.different.formatted()). When combining the notebooks, both versions of those days are kept.")
            : String(localized: "When combining the notebooks, all the days stay in that folder.")
        alert.addButton(withTitle: String(localized: "Combine"))
        alert.addButton(withTitle: String(localized: "Use Only That Folder"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        switch await alert.beginSheetModal(for: window) {
        case .alertFirstButtonReturn: return .move
        case .alertSecondButtonReturn: return .useOnly
        default: return .cancel
        }
    }

    private static func count(_ days: Int) -> String {
        days == 1 ? String(localized: "1 day") : String(localized: "\(days.formatted()) days")
    }

    private func say(_ title: String, _ text: String, on window: NSWindow) async {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        await alert.beginSheetModal(for: window)
    }

    // MARK: - The files (away from the main thread)

    private nonisolated static func inBackground<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(with: Result { try work() }) }
        }
    }

    private nonisolated static func inBackground<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
        }
    }

    private nonisolated static func prepare(_ folder: URL) -> Bool {
        (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil
            && FileManager.default.isWritableFile(atPath: folder.path)
    }

    private nonisolated static func survey(_ source: URL, _ target: URL) throws -> Survey {
        let names = NotebookFiles.names(in: source)
        let there = Set(NotebookFiles.names(in: target).filter(NotebookFiles.isDay))
        var different = 0
        for name in names where NotebookFiles.isDay(name) && there.contains(name) {
            if try NotebookFiles.read(source.appendingPathComponent(name)) != NotebookFiles.read(target.appendingPathComponent(name)) { different += 1 }
        }
        return Survey(names: names, days: names.filter(NotebookFiles.isDay).count, daysThere: there.count, different: different)
    }

    /// Copies to a hidden folder next to where the files will end up and compares each copy with its
    /// original. Only when all of them match do they take their places, and any failure undoes that.
    private nonisolated static func transfer(_ names: [String], from source: URL, to target: URL, progress: (Int) -> Void) throws {
        let files = FileManager.default
        try files.createDirectory(at: target, withIntermediateDirectories: true)
        let staging = target.appendingPathComponent(".essais-moviendo-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: staging) }

        for (i, name) in names.enumerated() {
            let original = try NotebookFiles.read(source.appendingPathComponent(name))
            let copy = staging.appendingPathComponent(name)
            try original.write(to: copy, options: .atomic)
            guard try Data(contentsOf: copy) == original else { throw CocoaError(.fileWriteUnknown) }
            progress(i + 1)
        }

        var undo: [() -> Void] = []
        do {
            for name in names {
                let staged = staging.appendingPathComponent(name)
                var final = target.appendingPathComponent(name)
                if files.fileExists(atPath: final.path) {
                    let there = try NotebookFiles.read(final)
                    if try there == Data(contentsOf: staged) || name == NotebookFiles.mark { continue }
                    if NotebookFiles.isDay(name) {
                        // Both versions stay: the one that was there goes beside it, as any conflict does.
                        let aside = uniqueAside(for: name, in: target)
                        try files.moveItem(at: final, to: aside)
                        let moved = final
                        undo.append { try? files.moveItem(at: aside, to: moved) }
                    } else {
                        final = uniqueAside(for: name, in: target)
                    }
                }
                try files.moveItem(at: staged, to: final)
                let placed = final
                undo.append { try? files.removeItem(at: placed) }
            }
        } catch {
            for step in undo.reversed() { step() }
            throw error
        }
    }

    private nonisolated static func uniqueAside(for name: String, in folder: URL) -> URL {
        let stem = String(name.dropLast(3))
        var url = folder.appendingPathComponent("\(stem) (otra versión).md")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(stem) (otra versión \(n)).md")
            n += 1
        }
        return url
    }

    /// The whole folder if only the notebook was in it. Otherwise only the notebook's files: whatever
    /// else lives there isn't Essais's to throw away.
    private nonisolated static func trashOriginal(_ names: [String], in source: URL) -> Bool {
        let moved = Set(names)
        let rest = ((try? FileManager.default.contentsOfDirectory(atPath: source.path)) ?? []).filter { name in
            if name == ".DS_Store" || moved.contains(name) { return false }
            if name.hasPrefix("."), name.hasSuffix(".icloud"), moved.contains(String(name.dropFirst().dropLast(7))) { return false }
            return true
        }
        do {
            if rest.isEmpty {
                try NotebookStore.moveToTrash(source)
            } else {
                for name in names { try NotebookStore.moveToTrash(source.appendingPathComponent(name)) }
            }
            return true
        } catch {
            NSLog("Essais: couldn't trash the previous folder: %@", String(describing: error))
            return false
        }
    }
}

/// The sheet that shows while the notebook moves.
@MainActor
private final class MoveProgress {
    let window: NSWindow
    private let bar = NSProgressIndicator()

    init(total: Int) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 90), styleMask: [.titled], backing: .buffered, defer: false)
        let label = NSTextField(labelWithString: String(localized: "Moving the notebook…"))
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = Double(max(1, total))
        bar.setAccessibilityLabel(label.stringValue)
        let stack = NSStackView(views: [label, bar])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        window.contentView = stack
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.widthAnchor.constraint(equalToConstant: 300).isActive = true
    }

    func update(_ done: Int) { bar.doubleValue = Double(done) }
}
