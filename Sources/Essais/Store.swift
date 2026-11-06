import Foundation

/// Test settings. Only in the QA build (scripts/build.sh --qa): the app people use reads none of them.
enum QA {
    static func env(_ key: String) -> String? {
        #if QA
        return ProcessInfo.processInfo.environment[key]
        #else
        return nil
        #endif
    }
}

/// What was written on one day. On disk: `YYYY-MM-DD.md`, plain markdown; the date is the file name.
struct Day {
    let key: String
    let date: Date
    var text: String
}

/// One markdown file per written day, in a visible folder any editor can open:
/// ~/Documents/Essais. Documents lives in iCloud Drive, so every read and write is
/// coordinated (that also downloads a file iCloud has evicted).
final class NotebookStore {
    let directory: URL
    /// What each file held when we last read or wrote it, to save only what changed and to
    /// notice when something else changed a file under us.
    private var saved: [String: String] = [:]
    /// Before the first change of a session to a day that isn't today, its text as it was: undo ends when
    /// the app closes, and an old day can be overwritten with a click and a key. Silent, for 90 days.
    private lazy var previous: URL = {
        if let custom = QA.env("ESSAIS_DIR") {
            return URL(fileURLWithPath: custom).deletingLastPathComponent().appendingPathComponent("anteriores-prueba", isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Essais/Anteriores", isDirectory: true)
    }()
    private var keptPrevious: Set<String> = []

    private func keepPrevious(_ text: String, key: String) {
        guard keptPrevious.insert(key).inserted else { return }
        let files = FileManager.default
        do {
            try files.createDirectory(at: previous, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HHmmss"
            try Data(text.utf8).write(to: previous.appendingPathComponent("\(key) antes de \(formatter.string(from: Date())).md"), options: .atomic)
            let limit = Date().addingTimeInterval(-90 * 24 * 3600)
            for file in try files.contentsOfDirectory(at: previous, includingPropertiesForKeys: [.contentModificationDateKey]) {
                if let date = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date < limit {
                    try? files.removeItem(at: file)
                }
            }
        } catch {
            NSLog("Essais: couldn't keep the previous text of %@: %@", key, String(describing: error))   // never stops a save
        }
    }

    /// Modification date and size of each day file as we last saw it, so a change in the folder
    /// costs reading the files that changed, not the whole notebook.
    private var stamps: [String: Stamp] = [:]
    private struct Stamp: Equatable {
        let modified: Date?
        let size: Int?
    }

    private static let dayName = try! NSRegularExpression(pattern: #"^(\d{4})-(\d{2})-(\d{2})\.md$"#)

    /// ESSAIS_DIR points the app at another folder (tests, development).
    init() {
        if let custom = QA.env("ESSAIS_DIR") {
            directory = URL(fileURLWithPath: custom, isDirectory: true)
        } else {
            directory = Self.documents.appendingPathComponent("Essais", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    /// File names are always Gregorian, whatever calendar the Mac shows (Buddhist, Japanese, Hebrew…).
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .autoupdatingCurrent   // a flight changes what "today" is
        return c
    }()

    static func key(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    static func date(_ key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        // Only real dates: 2026-13-45 isn't another day, it isn't a day at all.
        guard let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              calendar.dateComponents([.year, .month, .day], from: date) == DateComponents(year: parts[0], month: parts[1], day: parts[2])
        else { return nil }
        return date
    }

    /// Day files only: `2026-11-04.md`. Conflict copies and anything else in the folder are left alone.
    private func dayFiles() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { Self.dayName.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
    }

    var isEmpty: Bool { dayFiles().isEmpty }

    /// Day files that are there but couldn't be read in the last load.
    private(set) var unreadable: [String] = []

    /// The text of a day file: UTF-8, or what another editor may have saved it as (UTF-16 with its
    /// mark, Latin-1, Mac Roman). What isn't text at all is left alone.
    static func text(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let text = String(data: data, encoding: .utf8) { return text }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) { return String(data: data, encoding: .utf16) }
        guard !data.contains(0) else { return nil }
        return String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .macOSRoman)
    }

    #if QA
    /// Days whose text differs from what was last written (for tests).
    func unsaved(_ days: [Day]) -> [String] { days.filter { saved[$0.key] ?? "" != $0.text }.map(\.key) }
    #endif

    func load() -> [Day] {
        saved = [:]
        stamps = [:]
        var days: [Day] = []
        // One coordinated read of the whole folder (one per file took seconds with years of days).
        var texts: [String: String] = [:]
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: directory, options: [], error: &error) { folder in
            for name in dayFiles() { texts[name] = Self.text(at: folder.appendingPathComponent(name)) }
        }
        unreadable = []
        for name in dayFiles() {
            let key = String(name.dropLast(3))
            guard let date = Self.date(key) else { continue }
            guard let text = texts[name] else { unreadable.append(key); continue }
            saved[key] = text
            stamps[name] = stamp(name)
            // An empty day is only a date line; it isn't worth one.
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            days.append(Day(key: key, date: date, text: text))
        }
        return days.sorted { $0.key < $1.key }
    }

    /// Writes only the days whose text changed. A day left empty goes to the Trash. If the file
    /// changed on disk since we read it (another Mac, another editor), that version is kept
    /// beside it as `YYYY-MM-DD (otra versión).md` before ours replaces it.
    /// What a save had to do that the writer should know about.
    struct SaveReport {
        var keptAside: [URL] = []
        var failed: [(day: String, error: Error)] = []
    }

    /// A day file that is there but can't be read: still in iCloud with no connection, saved by another
    /// app in an encoding Essais doesn't read, or without permission. Essais never writes over it.
    struct UnreadableFile: LocalizedError {
        var errorDescription: String? {
            String(localized: "Its file is in the Essais folder but couldn’t be read, so it was left as it is. It may still be downloading from iCloud.")
        }
    }

    /// Nothing that wasn't read is ever replaced or thrown away: a file that's there but unreadable is
    /// left alone, a file we never read (another Mac wrote it) isn't taken for a day we emptied, and a
    /// version we didn't write is kept beside ours.
    @discardableResult
    func save(_ days: [Day]) -> SaveReport {
        var report = SaveReport()
        for day in days where saved[day.key] != day.text {
            let url = directory.appendingPathComponent(day.key + ".md")
            let empty = day.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let exists = FileManager.default.fileExists(atPath: url.path)
            let disk = exists ? read(url) : nil
            if let disk, disk != day.text, day.key != Self.key(Date()) { keepPrevious(disk, key: day.key) }
            if exists, disk == nil {
                if !empty { report.failed.append((day.key, UnreadableFile())) }
                continue
            }
            do {
                if empty {
                    // Only what we read or wrote, unchanged since, goes to the Trash. Anything else is
                    // someone else's writing: changedOnDisk() brings it in.
                    if let disk, disk != saved[day.key] { continue }
                    if exists { try trash(url) }
                    stamps[url.lastPathComponent] = nil
                } else {
                    if let disk, disk != day.text, disk != saved[day.key],
                       !disk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        // The other version just continues this one: no conflict, it comes in (changedOnDisk).
                        if disk.hasPrefix(day.text) { continue }
                        // This one continues the other: nothing of theirs is lost by writing it.
                        if !day.text.hasPrefix(disk) {
                            guard let aside = keepAside(disk, key: day.key) else { throw UnreadableFile() }
                            if !report.keptAside.contains(aside), asideTold.insert(aside).inserted { report.keptAside.append(aside) }
                        }
                    }
                    try write(day.text, to: url)
                    stamps[url.lastPathComponent] = stamp(url.lastPathComponent)
                }
                saved[day.key] = day.text
            } catch {
                NSLog("Essais: couldn't save %@: %@", day.key, String(describing: error))
                report.failed.append((day.key, error))
            }
        }
        return report
    }

    /// True when a day file was added, removed or rewritten by someone else (another Mac through
    /// iCloud, another editor) since we last read or wrote it.
    func changedOnDisk() -> Bool {
        let names = Set(dayFiles())
        let known = Set(stamps.keys)
        let added = names.subtracting(known).filter { name in
            // A new file only matters if it has something in it.
            !(read(directory.appendingPathComponent(name)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if !added.isEmpty || !known.subtracting(names).isEmpty { return true }
        for name in names where stamp(name) != stamps[name] {
            let key = String(name.dropLast(3))
            if read(directory.appendingPathComponent(name)) != saved[key] { return true }
            stamps[name] = stamp(name)   // touched, same text (iCloud does this)
        }
        return false
    }

    private func stamp(_ name: String) -> Stamp {
        let values = try? directory.appendingPathComponent(name).resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return Stamp(modified: values?.contentModificationDate, size: values?.fileSize)
    }

    /// One copy of the other version per day and session: two Macs writing at once left a new file
    /// on every save. The next conflict of the session replaces it only if it holds the same text or
    /// more; a different text still gets its own file.
    private var asideThisSession: [String: (url: URL, text: String)] = [:]
    private var asideTold: Set<URL> = []

    private func keepAside(_ text: String, key: String) -> URL? {
        if let last = asideThisSession[key], text == last.text || text.hasPrefix(last.text) {
            return (try? write(text, to: last.url)) != nil ? remember(text, last.url, key) : nil
        }
        var url = directory.appendingPathComponent("\(key) (otra versión).md")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(key) (otra versión \(n)).md")
            n += 1
        }
        return (try? write(text, to: url)) != nil ? remember(text, url, key) : nil
    }

    private func remember(_ text: String, _ url: URL, _ key: String) -> URL {
        asideThisSession[key] = (url, text)
        return url
    }


    // MARK: - Coordinated file access

    func read(_ url: URL) -> String? {
        var result: String?
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { url in
            result = Self.text(at: url)
        }
        return result
    }

    private func write(_ text: String, to url: URL) throws {
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { url in
            do { try Data(text.utf8).write(to: url, options: .atomic) } catch { writeError = error }
        }
        if let error = coordinationError ?? writeError { throw error }
    }

    /// iCloud Drive sometimes refuses the Trash (error 513); then the file goes to ~/.Trash by hand.
    private func trash(_ url: URL) throws {
        var coordinationError: NSError?
        var trashError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { url in
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch {
                let bin = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
                let stamp = Int(Date().timeIntervalSince1970)
                do { try FileManager.default.moveItem(at: url, to: bin.appendingPathComponent("\(stamp) \(url.lastPathComponent)")) }
                catch { trashError = error }
            }
        }
        if let error = coordinationError ?? trashError { throw error }
    }

    #if QA
    /// A week of example writing (ESSAIS_SAMPLE=1 with an empty ESSAIS_DIR).
    func seedIfEmpty() {
        guard QA.env("ESSAIS_SAMPLE") == "1", isEmpty else { return }
        let today = Calendar.current.startOfDay(for: Date())
        for (offset, text) in Sample.days {
            guard let date = Calendar.current.date(byAdding: .day, value: offset, to: today) else { continue }
            try? Data(text.utf8).write(to: directory.appendingPathComponent(Self.key(date) + ".md"))
        }
    }
    #endif
}

#if QA
enum Sample {
    static let days: [(Int, String)] = [
        (-9, """
        Hoy me desperté antes de la alarma y me quedé un rato mirando el techo. Hay algo en esos minutos sin nada que hacer que me ordena más que cualquier lista.

        Caminé hasta la rambla antes de la facultad. El agua estaba gris y quieta, y por un rato no pensé en nada. #rutina
        """),
        (-8, """
        > «La felicidad es una actividad del alma conforme a la virtud.» — Aristóteles, Ética a Nicómaco, libro I

        Lo anoto para no olvidarlo. Me sorprende que para él la felicidad no sea un estado al que se llega, sino algo que se hace. #lectura #aristóteles
        """),
        (-6, """
        # Reflexiones de mi lectura de la Ética a Nicómaco

        Empecé el libro pensando que iba a ser un manual de cómo vivir, y en cierto sentido lo es, pero no del modo que esperaba. Aristóteles no da reglas: describe hábitos. La virtud, dice, se adquiere practicándola, como se aprende a tocar la cítara tocando.

        Eso me incomoda un poco. Quisiera que hubiera un atajo, una idea que lo resolviera todo de una vez. Pero lo que propone es lo contrario: repetición, paciencia y un término medio que no se puede calcular de antemano, porque depende de la persona, del momento y de la situación.

        El ejemplo del valiente me quedó dando vueltas. No es el que no tiene miedo, sino el que siente el miedo justo, por las razones justas, en el momento justo. Hay algo muy humano en esa idea de justeza: no se trata de eliminar lo que sentimos, sino de afinarlo.

        Pienso en cuántas veces confundí la valentía con la temeridad, o la prudencia con la cobardía. Aristóteles diría que no supe ver el término medio, y que solo se aprende a verlo equivocándose. Me consuela un poco: equivocarse no es fracasar en la virtud, es parte de aprenderla.

        Hay otra idea que me parece hermosa: que el placer acompaña a la actividad bien hecha, como la juventud acompaña a los jóvenes. No es el objetivo, es lo que aparece cuando uno hace bien lo que hace.
        """),
        (-5, """
        Sigo con lo de ayer. Creo que lo que más me interesa es que la virtud sea un hábito y no una decisión heroica. Escribir todos los días se parece a eso: no hay un día en que uno se vuelve escritor, hay muchos días en que uno escribe.

        Me pregunto si este cuaderno es, de alguna forma, una práctica en ese sentido. No para llegar a algún lado, sino para ir siendo alguien que piensa por escrito. #lectura #escritura
        """),
        (-3, """
        Domingo lento. Almorzamos con mis viejos y mi vieja preguntó otra vez qué pienso hacer cuando me reciba. No supe qué decir, y por primera vez no me angustió no saberlo.

        A la tarde ordené libros y encontré cartas viejas de mi abuela. Su letra inclinada, las tildes que nunca ponía. Me quedé leyendo hasta que se hizo de noche. #familia
        """),
        (-1, """
        Lluvia toda la tarde. Terminé el informe de redes y me quedé leyendo hasta tarde. Anoto una frase que encontré:

        > «Somos lo que hacemos repetidamente.» — atribuida a Aristóteles, aunque en realidad es de Will Durant

        Me hace gracia que la frase más citada de Aristóteles no sea suya. #lectura
        """),
    ]
}

#endif

/// Calls back (debounced, on the main queue) when anything in a folder changes on disk. FSEvents
/// sees every writer: iCloud downloading from another Mac, an editor, Finder, a script.
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void

    init(_ folder: URL, onChange: @escaping () -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        guard let stream = FSEventStreamCreate(nil, callback, &context, [folder.path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5,
                                               // Our own saves don't count: they'd wake the app to look at what it just wrote.
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagIgnoreSelf)) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
