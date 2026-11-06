import AppKit
import Sparkle

/// Updates through Sparkle: checks docs/appcast.xml on the website once a day and offers each new
/// release in Sparkle's own window. Nothing installs without asking.
@MainActor
final class Updater: NSObject, SPUUpdaterDelegate, NSMenuItemValidation {
    static let shared = Updater()
    private lazy var controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)

    func start() { _ = controller }

    @objc func checkForUpdates(_ sender: Any?) {
        NSApp.activate()
        controller.checkForUpdates(sender)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool { controller.updater.canCheckForUpdates }

    var checksAutomatically: Bool {
        get {
            #if QA
            // The test copy never starts the updater just to show a setting.
            return UserDefaults.standard.object(forKey: "SUEnableAutomaticChecks") as? Bool ?? true
            #else
            return controller.updater.automaticallyChecksForUpdates
            #endif
        }
        set {
            #if QA
            UserDefaults.standard.set(newValue, forKey: "SUEnableAutomaticChecks")
            #else
            controller.updater.automaticallyChecksForUpdates = newValue
            #endif
        }
    }

    #if QA
    /// ESSAIS_FEED: a local feed, to try a whole update on the machine.
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? { QA.env("ESSAIS_FEED") }

    /// Downloads, verifies and leaves the update to install on quit, with no windows.
    func installInBackground() {
        controller.updater.automaticallyDownloadsUpdates = true
        controller.updater.checkForUpdatesInBackground()
    }
    #endif
}
