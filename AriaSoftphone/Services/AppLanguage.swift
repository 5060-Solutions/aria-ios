import Foundation

/// The language the app runs in. It is chosen in iOS Settings > Aria >
/// Language (per-app language); the app never overrides it. iOS offers that
/// row for the languages the bundle declares in CFBundleLocalizations.
enum AppLanguage {
    /// The language code the bundle resolved for this launch.
    static func currentCode(bundle: Bundle = .main) -> String? {
        bundle.preferredLocalizations.first
    }

    /// The current language named in itself ("Español", "Deutsch").
    static func currentName(bundle: Bundle = .main) -> String {
        guard let code = currentCode(bundle: bundle) else { return "" }
        return name(forCode: code)
    }

    /// A language named in itself, so its own speakers can find it.
    static func name(forCode code: String) -> String {
        let locale = Locale(identifier: code)
        let name = locale.localizedString(forIdentifier: code) ?? code
        return name.capitalized(with: locale)
    }

    /// The languages the bundle declares and ships.
    static func declared(bundle: Bundle = .main) -> Set<String> {
        Set(bundle.infoDictionary?["CFBundleLocalizations"] as? [String] ?? [])
    }

    /// The languages with resources in the built bundle (Base excluded).
    static func shipped(bundle: Bundle = .main) -> Set<String> {
        Set(bundle.localizations.filter { $0 != "Base" })
    }
}
