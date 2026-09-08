import Foundation

/// Two-language UI strings, picked from the user's own language preference.
///
/// The app ships as a single binary built by `scripts/build.sh` (plain
/// `swiftc`, no resource bundle), so `.strings` files would not survive the
/// build. Call sites read as `L10n.t("English", "한국어")` — the English
/// wording first, because the README that brings people here is English.
enum L10n {
    /// True when the user's preferred language is Korean.
    static let isKorean: Bool = {
        // A forced override, mainly so screenshots can be taken in either
        // language without changing the system setting.
        if let forced = ProcessInfo.processInfo.environment["VIBECHECK_LANG"] {
            return forced.lowercased().hasPrefix("ko")
        }
        guard let preferred = Locale.preferredLanguages.first else { return false }
        return preferred.lowercased().hasPrefix("ko")
    }()

    static func t(_ english: String, _ korean: String) -> String {
        isKorean ? korean : english
    }

    /// Localized names for the runner animals, in the same order as
    /// `RunnerSettings.animals`.
    static func animalName(_ emoji: String) -> String {
        names[emoji] ?? t("runner", "러너")
    }

    private static let names: [String: String] = [
        "🐎": t("Horse", "말"), "🦄": t("Unicorn", "유니콘"),
        "🐫": t("Camel", "낙타"), "🐕": t("Dog", "개"),
        "🐈": t("Cat", "고양이"), "🐇": t("Rabbit", "토끼"),
        "🐢": t("Turtle", "거북이"), "🦖": t("T-Rex", "공룡"),
        "🐖": t("Pig", "돼지"), "🐄": t("Cow", "소"),
        "🦌": t("Deer", "사슴"), "🦘": t("Kangaroo", "캥거루"),
        "🐆": t("Cheetah", "치타"), "🐿️": t("Squirrel", "다람쥐"),
    ]
}
