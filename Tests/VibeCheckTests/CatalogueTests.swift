import Foundation
import Testing
@testable import VibeCheck

/// Adding an animal means touching three places: the display order, the pixel
/// art, and the names in both languages. Nothing in the compiler connects
/// them, so a species added to two of the three degrades silently — a runner
/// that falls back to the horse sprite, or one labelled "runner".
@Suite("Runner catalogue")
@MainActor
struct CatalogueTests {
    @Test("Every listed animal has its own sprite")
    func everyAnimalHasArt() {
        let horse = Sprites.frames(for: "🐎")[0].tiffRepresentation
        for animal in RunnerSettings.animals where animal != "🐎" {
            let frames = Sprites.frames(for: animal)
            #expect(frames.count == 4, "\(animal) should have four gait frames")
            // An unknown emoji silently falls back to the horse.
            #expect(frames[0].tiffRepresentation != horse,
                    "\(animal) has no Species of its own — it renders as the horse")
        }
    }

    @Test("Every listed animal is named in both languages")
    func everyAnimalIsNamed() {
        for animal in RunnerSettings.animals {
            for korean in [false, true] {
                let name = korean ? L10n.animalNameKO(animal) : L10n.animalNameEN(animal)
                #expect(!name.isEmpty)
                #expect(name != L10n.animalNameEN("\u{1F984}\u{1F984}"),
                        "\(animal) falls back to the generic name in \(korean ? "ko" : "en")")
            }
        }
    }

    @Test("The catalogue has no duplicates")
    func noDuplicates() {
        #expect(Set(RunnerSettings.animals).count == RunnerSettings.animals.count)
    }

    @Test("Each assistant's default animal is one of the listed ones")
    func defaultsAreListed() {
        for assistant in ProcessMonitor.assistants {
            #expect(RunnerSettings.animals.contains(assistant.runnerEmoji),
                    "\(assistant.id) defaults to \(assistant.runnerEmoji), which is not offered")
        }
    }

    @Test("Assistant ids are unique and each has a transcript decision")
    func assistantsAreCoherent() {
        let ids = ProcessMonitor.assistants.map(\.id)
        #expect(Set(ids).count == ids.count)
        for assistant in ProcessMonitor.assistants {
            // Either a reader exists, or the README's table says it does not.
            let hasReader = Transcripts.reader(for: assistant.id) != nil
            #expect(hasReader == (assistant.id != "gemini"),
                    "\(assistant.id): reader presence changed — update the README table")
        }
    }
}
