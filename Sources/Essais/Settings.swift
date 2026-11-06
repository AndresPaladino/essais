import AppKit
import SwiftUI

extension Notification.Name {
    /// A setting changed somewhere else (Aa, a menu, a shortcut): the Settings window shows it.
    static let essaisSettingsChanged = Notification.Name("EssaisSettingsChanged")
}

enum Look: String, CaseIterable, Identifiable {
    case automatic, light, dark
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .automatic: "Automatic"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
    var appearance: NSAppearance? {
        switch self {
        case .automatic: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

enum DateLanguage: String, CaseIterable, Identifiable {
    case system, spanish, english
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .system: "Same as System"
        case .spanish: "Español"
        case .english: "English"
        }
    }
    var locale: Locale {
        switch self {
        case .system: .autoupdatingCurrent
        case .spanish: Locale(identifier: "es")
        case .english: Locale(identifier: "en")
        }
    }
}

extension WritingOption {
    var title: LocalizedStringKey {
        switch self {
        case .spelling: "Check Spelling While Typing"
        case .grammar: "Check Grammar With Spelling"
        case .autocorrect: "Correct Spelling Automatically"
        case .quotes: "Smart Quotes"
        case .dashes: "Smart Dashes"
        case .replacement: "Text Replacement"
        }
    }
}

enum Preferences {
    private static var defaults: UserDefaults { .standard }

    static var look: Look {
        get { Look(rawValue: defaults.string(forKey: "look") ?? "") ?? .automatic }
        set { defaults.set(newValue.rawValue, forKey: "look") }
    }
    static var dateLanguage: DateLanguage {
        get { DateLanguage(rawValue: defaults.string(forKey: "dateLanguage") ?? "") ?? .system }
        set { defaults.set(newValue.rawValue, forKey: "dateLanguage") }
    }
    /// The notebook's folder, when it isn't the usual one.
    static var folder: String? {
        get { defaults.string(forKey: "folder") }
        set { defaults.set(newValue, forKey: "folder") }
    }
    static var welcomed: Bool {
        get { defaults.bool(forKey: "welcomed") }
        set { defaults.set(newValue, forKey: "welcomed") }
    }
}

/// What the Settings window and the welcome change. Everything applies at once.
@MainActor
final class SettingsModel: ObservableObject {
    private let notebook: NotebookController
    private let store: NotebookStore
    private var observer: NSObjectProtocol?

    init(notebook: NotebookController, store: NotebookStore) {
        self.notebook = notebook
        self.store = store
        observer = NotificationCenter.default.addObserver(forName: .essaisSettingsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.objectWillChange.send() }
        }
    }

    deinit { observer.map(NotificationCenter.default.removeObserver) }

    var font: Fonts {
        get { Reading.font }
        set { objectWillChange.send(); Reading.font = newValue; notebook.readingChanged() }
    }

    var size: Int { Int(Reading.size) }
    var canShrink: Bool { Reading.size > Reading.sizes.lowerBound }
    var canGrow: Bool { Reading.size < Reading.sizes.upperBound }
    func changeSize(by delta: CGFloat) {
        objectWillChange.send()
        Reading.size += delta
        notebook.readingChanged()
        notebook.announceSize()
    }

    var look: Look {
        get { Preferences.look }
        set { objectWillChange.send(); Preferences.look = newValue; NSApp.appearance = newValue.appearance }
    }

    var dateLanguage: DateLanguage {
        get { Preferences.dateLanguage }
        set { objectWillChange.send(); Preferences.dateLanguage = newValue; notebook.dateLanguageChanged() }
    }

    func option(_ option: WritingOption) -> Binding<Bool> {
        Binding(get: { [notebook] in notebook.writingOption(option) },
                set: { [weak self] value in
                    self?.objectWillChange.send()
                    self?.notebook.setWritingOption(option, to: value)
                })
    }

    var checksForUpdates: Bool {
        get { Updater.shared.checksAutomatically }
        set { objectWillChange.send(); Updater.shared.checksAutomatically = newValue }
    }
    func checkForUpdates() { Updater.shared.checkForUpdates(nil) }

    var folderLabel: String { NotebookFiles.label(for: store.directory) }
    var isInDefaultFolder: Bool { store.directory.standardizedFileURL.path == NotebookStore.defaultDirectory.standardizedFileURL.path }
    var defaultFolderLabel: String { NotebookFiles.label(for: NotebookStore.defaultDirectory) }
    func showFolder() { NSWorkspace.shared.activateFileViewerSelecting([store.directory]) }

    func showPrevious() {
        try? FileManager.default.createDirectory(at: store.previousFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([store.previousFolder])
    }

    func changeFolder(from window: NSWindow?) {
        guard let window else { return }
        Task {
            await NotebookMover(notebook: notebook, store: store).chooseFolder(from: window)
            objectWillChange.send()
        }
    }

    func useDefaultFolder(from window: NSWindow?) {
        guard let window else { return }
        Task {
            await NotebookMover(notebook: notebook, store: store).move(to: NotebookStore.defaultDirectory, from: window)
            objectWillChange.send()
        }
    }

    var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }
}

/// The date line and a sentence, as the notebook shows them with the current choices.
struct WritingSample: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Reading.dateLine(Date(), day: "").string.trimmingCharacters(in: .newlines))
                .font(.system(size: 10.5, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(.secondary)
            Text("Today I walked to the waterfront and stayed to read for a while.")
                .font(Font(Reading.body as CTFont))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(nsColor: Paper.sheet), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Sample text"))
    }
}

struct SizeControl: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        HStack(spacing: 4) {
            Button { model.changeSize(by: -1) } label: { Text(verbatim: "A").font(.system(size: 11)).frame(width: 22) }
                .disabled(!model.canShrink)
                .accessibilityLabel(Text("Smaller Text"))
            Text(verbatim: "\(model.size)")
                .monospacedDigit()
                .frame(width: 30)
            Button { model.changeSize(by: 1) } label: { Text(verbatim: "A").font(.system(size: 15)).frame(width: 22) }
                .disabled(!model.canGrow)
                .accessibilityLabel(Text("Bigger Text"))
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    let height: CGFloat
    let window: () -> NSWindow?

    var body: some View {
        Form {
            Section("Writing") {
                WritingSample(model: model)
                Picker("Font", selection: $model.font) {
                    ForEach(Fonts.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
                }
                LabeledContent("Size") { SizeControl(model: model) }
            }
            Section("Corrections and Substitutions") {
                ForEach(WritingOption.allCases) { option in
                    Toggle(option.title, isOn: model.option(option))
                }
            }
            Section("Appearance") {
                Picker("Mode", selection: $model.look) {
                    ForEach(Look.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Date Language", selection: $model.dateLanguage) {
                    ForEach(DateLanguage.allCases) { Text($0.title).tag($0) }
                }
            }
            Section("Notebook") {
                LabeledContent {
                    HStack {
                        Button("Show in Finder") { model.showFolder() }
                        Button("Change…") { model.changeFolder(from: window()) }
                    }
                } label: {
                    Text("Folder")
                    Text(verbatim: model.folderLabel)
                }
                LabeledContent {
                    Button("Show Copies") { model.showPrevious() }
                } label: {
                    Text("Previous Days")
                    Text("When you edit a previous day, a copy is kept for 90 days.")
                }
            }
            Section("Updates") {
                Toggle(isOn: $model.checksForUpdates) {
                    Text("Check Automatically")
                    Text("Once a day. Updates require confirmation.")
                }
                LabeledContent {
                    Button("Check Now") { model.checkForUpdates() }
                } label: {
                    Text(verbatim: "Essais \(model.version)")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: height)
    }
}

/// One window, like the settings of Notes: everything at a glance.
@MainActor
final class SettingsWindowController: NSWindowController {
    init(model: SettingsModel) {
        // A window of its own size, not the whole height of the screen: the form scrolls.
        let height = min(640, (NSScreen.main?.visibleFrame.height ?? 800) - 80)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: height),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = String(localized: "Settings")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentViewController = NSHostingController(rootView: SettingsView(model: model, height: height) { [weak window] in window })
        window.center()
        window.setFrameAutosaveName("Settings")
        // The saved frame brings back its place, never another size.
        window.setContentSize(NSSize(width: 560, height: height))
    }

    required init?(coder: NSCoder) { fatalError() }
}
