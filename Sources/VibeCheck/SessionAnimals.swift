import Foundation

/// Assigns each live session (terminal) its own animal, stable for the
/// session's lifetime. Distinct sessions get distinct animals when possible.
/// Main-thread only.
enum SessionAnimals {
    private static var assigned: [Int32: (assistantID: String, emoji: String)] = [:]

    static func emoji(for session: SessionStatus) -> String {
        if let entry = assigned[session.pid] { return entry.emoji }

        let preferred = RunnerSettings.storedValue(for: session.assistant)
        let used = Set(assigned.values.map(\.emoji))
        let pick: String
        if preferred != RunnerSettings.randomValue, !used.contains(preferred) {
            pick = preferred
        } else {
            let available = RunnerSettings.animals.map(\.emoji).filter { !used.contains($0) }
            pick = available.randomElement() ?? RunnerSettings.animals.randomElement()!.emoji
        }
        assigned[session.pid] = (session.assistant.id, pick)
        return pick
    }

    static func prune(livePids: Set<Int32>) {
        assigned = assigned.filter { livePids.contains($0.key) }
    }

    /// Drops one assistant's assignments so its sessions re-pick
    /// (called after the user changes that assistant's animal preference).
    static func reset(assistantID: String) {
        assigned = assigned.filter { $0.value.assistantID != assistantID }
    }
}
