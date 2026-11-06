import AppKit
import SwiftUI

/// The first time, with an empty notebook: what Essais is, and the choices that change what you see
/// from the first line. The rest has its defaults and lives in Settings.
final class WelcomeProgress: ObservableObject {
    @Published var step = 0
}

struct WelcomeView: View {
    @ObservedObject var model: SettingsModel
    // Kept in an object: building with the Command Line Tools alone, SwiftUI's @State isn't available.
    @ObservedObject var progress: WelcomeProgress
    let window: () -> NSWindow?
    let finish: () -> Void

    private var step: Int { progress.step }

    var body: some View {
        VStack(spacing: 18) {
            Group {
                switch step {
                case 0: introduction
                case 1: writing
                default: location
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            footer
        }
        .padding(EdgeInsets(top: 30, leading: 38, bottom: 24, trailing: 38))
        .frame(width: 470, height: 510)
    }

    private var introduction: some View {
        VStack(spacing: 22) {
            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                    .accessibilityHidden(true)
                Text(verbatim: "Essais").font(.system(size: 27, weight: .semibold, design: .serif))
                Text("A continuous notebook for Mac").foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 18) {
                feature("pencil.line", "One Notebook", "Each day begins with its date. There are no folders or entries to name.")
                feature("number", "Titles and Topics", "Lines with # and words with #topic appear in the Index.")
                feature("folder", "Text Files", "Each day is saved as a text file. No account is required.")
            }
        }
    }

    private func feature(_ symbol: String, _ title: LocalizedStringKey, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func heading(_ title: LocalizedStringKey, _ text: LocalizedStringKey) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.system(size: 27, weight: .semibold, design: .serif))
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var writing: some View {
        VStack(spacing: 16) {
            heading("Font", "This can be changed later in Aa or in Settings.")
            WritingSample(model: model).frame(height: 116, alignment: .top).clipped()
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 8) {
                ForEach(Fonts.allCases, id: \.self) { font in fontChoice(font) }
            }
            HStack {
                Text("Size")
                Spacer()
                SizeControl(model: model)
            }
            HStack {
                Text("Appearance")
                Spacer()
                Picker("Appearance", selection: $model.look) {
                    ForEach(Look.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }
        }
    }

    private func fontChoice(_ font: Fonts) -> some View {
        Button { model.font = font } label: {
            VStack(spacing: 2) {
                Text(verbatim: "Aa").font(Font(font.font(20) as CTFont))
                Text(verbatim: font == .iowan ? "Iowan" : font.title).font(.caption).lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            if model.font == font { RoundedRectangle(cornerRadius: 10).stroke(.tint, lineWidth: 2) }
        }
        .accessibilityLabel(Text(verbatim: font.title))
        .accessibilityAddTraits(model.font == font ? .isSelected : [])
    }

    private var location: some View {
        VStack(spacing: 18) {
            heading("Location", "Each day is saved as a text file that any editor can open.")
            VStack(spacing: 8) {
                place(model.defaultFolderLabel, "Syncs with iCloud Drive if Desktop & Documents is turned on.", symbol: "folder", selected: model.isInDefaultFolder) {
                    model.useDefaultFolder(from: window())
                }
                place(model.isInDefaultFolder ? String(localized: "Other Folder…") : model.folderLabel, "Dropbox, an external drive or another location.", symbol: "folder.badge.plus", selected: !model.isInDefaultFolder) {
                    model.changeFolder(from: window())
                }
            }
        }
    }

    private func place(_ title: String, _ text: LocalizedStringKey, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title).fontWeight(.semibold)
                    Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            if selected { RoundedRectangle(cornerRadius: 12).stroke(.tint, lineWidth: 2) }
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var footer: some View {
        HStack {
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { i in
                    Circle().fill(i == step ? Color.primary : Color.secondary.opacity(0.3)).frame(width: 7, height: 7)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Step \(step + 1) of 3"))
            Spacer()
            if step > 0 {
                Button("Back") { progress.step -= 1 }
                    .controlSize(.large)
                    .keyboardShortcut(.cancelAction)
            }
            Button(step < 2 ? "Continue" : "Start") {
                if step < 2 { progress.step += 1 } else { finish() }
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
    }
}

@MainActor
final class WelcomeSheet {
    private let sheet: NSWindow
    private weak var parent: NSWindow?

    init(model: SettingsModel, parent: NSWindow, finished: @escaping () -> Void) {
        self.parent = parent
        sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 510), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        sheet.contentViewController = NSHostingController(rootView: WelcomeView(model: model, progress: WelcomeProgress(), window: { [weak sheet] in sheet }) { [weak parent, weak sheet] in
            if let sheet { parent?.endSheet(sheet) }
            finished()
        })
    }

    func show() { parent?.beginSheet(sheet) }
}
