import Foundation

/// Per-assistant animal preference, persisted in UserDefaults.
/// The preference seeds session animals: an assistant's first session gets the
/// preferred animal; further sessions get distinct ones (see SessionAnimals).
enum RunnerSettings {
    static let animals: [(emoji: String, name: String)] = [
        ("🐎", "말"), ("🦄", "유니콘"), ("🐫", "낙타"), ("🐕", "개"),
        ("🐈", "고양이"), ("🐇", "토끼"), ("🐢", "거북이"), ("🦖", "공룡"),
        ("🐖", "돼지"), ("🐄", "소"), ("🦌", "사슴"), ("🦘", "캥거루"),
        ("🐆", "치타"), ("🐿️", "다람쥐"),
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
