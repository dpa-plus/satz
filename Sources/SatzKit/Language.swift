import Foundation

/// The language satz speaks: German or English.
///
/// Two languages, written side by side at each use with `de(_:en:)`, rather
/// than string tables: the whole interface is a few dozen labels, and a
/// missing translation is then a compile error instead of a key on screen.
public enum Language: String, CaseIterable, Codable, Sendable {
    case german = "de"
    case english = "en"

    /// Set by the app from its preference; read by every label.
    nonisolated(unsafe) public static var current: Language = .system

    /// German if the Mac's first language is German, English otherwise.
    public static var system: Language {
        Locale.preferredLanguages.first?.lowercased().hasPrefix("de") == true ? .german : .english
    }

    /// The language's name in itself, for the switch in Settings.
    public var name: String {
        switch self {
        case .german: "Deutsch"
        case .english: "English"
        }
    }
}

/// The German or the English text, by the app's current language.
public func de(_ german: String, en english: String) -> String {
    Language.current == .english ? english : german
}
