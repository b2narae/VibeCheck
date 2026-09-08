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

    /// The two language-pinned lookups, so a test can check that every animal
    /// is named in both rather than only in whichever one is active.
    static func animalNameEN(_ emoji: String) -> String { english[emoji] ?? "runner" }
    static func animalNameKO(_ emoji: String) -> String { korean[emoji] ?? "러너" }

    private static let names: [String: String] = isKorean ? korean : english

    private static let english: [String: String] = [
        "🐎": "Horse", "🦄": "Unicorn", "🐫": "Camel", "🐕": "Dog",
        "🐈": "Cat", "🐇": "Rabbit", "🐢": "Turtle", "🦖": "T-Rex",
        "🐖": "Pig", "🐄": "Cow", "🦌": "Deer", "🦘": "Kangaroo",
        "🐆": "Cheetah", "🐿️": "Squirrel",
    ]

    private static let korean: [String: String] = [
        "🐎": "말", "🦄": "유니콘", "🐫": "낙타", "🐕": "개",
        "🐈": "고양이", "🐇": "토끼", "🐢": "거북이", "🦖": "공룡",
        "🐖": "돼지", "🐄": "소", "🦌": "사슴", "🦘": "캥거루",
        "🐆": "치타", "🐿️": "다람쥐",
    ]
}
