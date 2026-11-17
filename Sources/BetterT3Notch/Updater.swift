import AppKit
import Sparkle

/// In-app updates through Sparkle. Release builds carry a feed URL and public key in
/// Info.plist (build.sh adds them); a local build without the key never checks.
@MainActor
enum Updater {
    /// Sparkle refuses a feed without a key, so a build missing one has no updater at all.
    static let isAvailable = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String != nil

    private static let controller: SPUStandardUpdaterController? = isAvailable
        ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        : nil

    /// Starts the background schedule. Call once at launch.
    static func start() { _ = controller }

    static func checkNow() {
        NSApp.activate() // the update window is a normal window; an agent app has to come forward for it
        controller?.checkForUpdates(nil)
    }

    static var checksAutomatically: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}
