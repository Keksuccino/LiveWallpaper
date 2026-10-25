import AppKit
import Core

// The language the app is shown in: the Mac's (the default) or one of the app's own translations, picked in
// Settings > General. It is stored the way macOS stores a per-app language (System Settings > General > Language &
// Region > Applications): `AppleLanguages` in the app's own defaults domain, so both places show the same choice.
// The service's domain gets the same value: its menu and the messages it reports follow the app's language.
// A bundle picks its language once, at launch, so a change shows once both apps have restarted (`restart()`).

@MainActor final class AppLanguage: ObservableObject {
    static let shared = AppLanguage()

    /// Launch argument of the copy `restart()` opens: it shows Settings at General again.
    static let reopenSettingsArgument = "--reopen-language-settings"

    /// The app's translations (their lproj names), in the order of their names.
    let available: [String]
    /// The translation the Mac's own language order picks.
    let system: String
    /// The translation this copy of the app shows; picked at launch, it never changes while the app runs.
    let running: String
    /// The chosen translation; nil follows the Mac.
    @Published var selection: String? { didSet { if selection != oldValue { store() } } }
    /// From `restart()` until the app quits.
    @Published private(set) var isRestarting = false

    private let names: [String: String]
    private static let key = "AppleLanguages" as CFString

    private init() {
        // Bundle.localizations holds Info.plist's CFBundleLocalizations and then the lproj folders: most codes twice.
        let codes = Array(Set(Bundle.main.localizations).subtracting(["Base"]))
        let names = Dictionary(uniqueKeysWithValues: codes.map { ($0, Self.nativeName(of: $0, among: codes)) })
        self.names = names
        let available = codes.sorted { names[$0]!.localizedStandardCompare(names[$1]!) == .orderedAscending }
        self.available = available
        let fallback = Bundle.main.developmentLocalization ?? "en"
        let preferred = Self.read(kCFPreferencesAnyApplication) ?? []
        system = Bundle.preferredLocalizations(from: available, forPreferences: preferred).first ?? fallback
        running = Bundle.main.preferredLocalizations.first ?? fallback
        selection = Self.read(AppIdentity.settingsBundleID as CFString)?.first.flatMap { Self.match($0, in: available) }
    }

    /// From applicationDidFinishLaunching: a language picked in System Settings is stored for Settings alone, so the
    /// service gets it too (from its next launch).
    static func shareWithService() {
        let own = read(AppIdentity.settingsBundleID as CFString)
        if own != read(AppIdentity.serviceBundleID as CFString) { write(own, to: AppIdentity.serviceBundleID) }
    }

    /// The translation the next launch shows differs from the one on screen.
    var needsRestart: Bool { (selection ?? system) != running }

    /// A translation's name in its own language ("Deutsch", "日本語").
    func name(of code: String) -> String { names[code, default: code] }

    /// Quits the service and this app and opens the app again, so both show the chosen language. The new copy opens
    /// Settings at General, where the user left it, and starts the service again as on every launch.
    func restart() {
        guard !isRestarting else { return }
        isRestarting = true
        Task { @MainActor in
            await ServiceClient.shared.quit()
            Self.openAgainAfterQuit()
            SettingsNavigator.shared.quitApp()
        }
    }

    private func store() {
        let value = selection.map { [$0] }
        for domain in [AppIdentity.settingsBundleID, AppIdentity.serviceBundleID] { Self.write(value, to: domain) }
    }

    /// `AppleLanguages` of one defaults domain alone (kCFPreferencesAnyApplication: the Mac's own list).
    private static func read(_ domain: CFString) -> [String]? {
        CFPreferencesCopyValue(key, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String]
    }

    /// nil removes the key: the app follows the Mac again.
    private static func write(_ languages: [String]?, to domain: String) {
        CFPreferencesSetValue(key, languages as CFArray?, domain as CFString, kCFPreferencesCurrentUser,
                              kCFPreferencesAnyHost)
        CFPreferencesSynchronize(domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    /// Opens this app again once this copy has quit: a shell waits for the process to end, since a copy that starts
    /// earlier would hand over to this one and quit (AppDelegate.yieldToRunningSettings). Should quitting be cancelled,
    /// the shell gives up after 10 s instead of opening the app whenever it quits later.
    private static func openAgainAfterQuit() {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = [
            "-c",
            "for _ in $(seq 100); do kill -0 \"$0\" 2>/dev/null || exec /usr/bin/open \"$1\" --args \"$2\"; sleep 0.1; done",
            String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundlePath, reopenSettingsArgument,
        ]
        do { try shell.run() } catch { NSLog("WallpaperMage: couldn’t schedule the relaunch: \(error.localizedDescription)") }
    }

    /// The translation a stored language stands for ("de-DE" → "de"); nil when the app has none of that language.
    private static func match(_ language: String, in codes: [String]) -> String? {
        if codes.contains(language) { return language }
        guard let best = Bundle.preferredLocalizations(from: codes, forPreferences: [language]).first,
              Locale.Language(identifier: best).languageCode == Locale.Language(identifier: language).languageCode
        else { return nil }
        return best
    }

    /// The name of `code` in that language, with the region when another translation shares the language: "es" next
    /// to "es-MX" is named for the region it stands for ("Español (España)").
    private static func nativeName(of code: String, among codes: [String]) -> String {
        let language = Locale.Language(identifier: code)
        let shared = codes.contains { $0 != code && Locale.Language(identifier: $0).languageCode == language.languageCode }
        var shown = code
        if shared, language.region == nil, let languageCode = language.languageCode,
           let region = Locale.Language(identifier: language.maximalIdentifier).region {
            shown = "\(languageCode.identifier)-\(region.identifier)"
        }
        let locale = Locale(identifier: code)
        guard let name = locale.localizedString(forIdentifier: shown) else { return code }
        return name.prefix(1).uppercased(with: locale) + name.dropFirst()
    }
}
