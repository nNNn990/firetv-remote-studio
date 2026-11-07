import Foundation

/// UI display language. The actual strings live in `Resources/<code>.lproj/Localizable.strings`;
/// macOS resolves them from the bundle at launch.
enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case japanese = "ja"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .english: return "English"
        case .japanese: return "日本語"
        }
    }
}

/// Stores the user's choice and applies it before SwiftUI resolves localised strings.
enum LanguageManager {
    static let defaultsKey = "displayLanguage"
    private(set) static var launchedLanguage: AppLanguage = .english

    /// The chosen language, falling back to the system language on first launch.
    static var current: AppLanguage {
        if let raw = UserDefaults.standard.string(forKey: defaultsKey),
           let saved = AppLanguage(rawValue: raw) { return saved }
        let code = Locale.preferredLanguages.first?.split(separator: "-").first.map(String.init)
        return code == "ja" ? .japanese : .english
    }

    /// Set `AppleLanguages` before the app bundle resolves its localisations.
    static func applyStoredLanguage() {
        launchedLanguage = current
        UserDefaults.standard.set([launchedLanguage.rawValue], forKey: "AppleLanguages")
    }

    /// Persist a new choice. It takes effect on the next launch.
    static func set(_ language: AppLanguage) {
        UserDefaults.standard.set(language.rawValue, forKey: defaultsKey)
        UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
    }
}
