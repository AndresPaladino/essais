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
