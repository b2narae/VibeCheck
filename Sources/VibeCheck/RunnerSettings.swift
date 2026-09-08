import Foundation

/// Per-assistant animal preference, persisted in UserDefaults.
/// The preference seeds session animals: an assistant's first session gets the
/// preferred animal; further sessions get distinct ones (see SessionAnimals).
enum RunnerSettings {
    /// Display order of the runner animals. Their names are localized in
    /// `L10n.animalName(_:)`.
    static let animals: [String] = [
        "🐎", "🦄", "🐫", "🐕", "🐈", "🐇", "🐢",
        "🦖", "🐖", "🐄", "🦌", "🦘", "🐆", "🐿️",
    ]

    /// Sentinel stored value meaning "always pick a random animal".
    static let randomValue = "random"

    private static func key(_ id: String) -> String { "runnerEmoji.\(id)" }

    static func storedValue(for assistant: Assistant) -> String {
        UserDefaults.standard.string(forKey: key(assistant.id)) ?? assistant.runnerEmoji
    }

    static func set(_ value: String, for assistant: Assistant) {
        UserDefaults.standard.set(value, forKey: key(assistant.id))
    }
}
