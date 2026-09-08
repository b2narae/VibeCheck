# Contributing

VibeCheck is a single native Swift binary with no dependencies. macOS 13+ and
the Xcode Command Line Tools are all you need.

```bash
git clone https://github.com/b2narae/VibeCheck.git && cd VibeCheck
swift test              # 60-odd tests, under a second
./scripts/make-app.sh   # build the .app and try it
open build/VibeCheck.app
```

Two builds exist and both must stay green:

- **`swift build` / `swift test`** — SwiftPM, Swift 6 language mode. This is the
  one CI and contributors reach for first.
- **`./scripts/build.sh`** — plain `swiftc`, which is what ships the app. It
  exists because some Command Line Tools installs have a broken SwiftPM
  manifest API, and it works around a stale `module.modulemap` when it finds
  one.

## Where things are

| File | What it does |
|---|---|
| `ProcessMonitor.swift` | Finds sessions, decides idle/working/blocked |
| `ProcessList.swift` | libproc + sysctl process table, CPU sampling |
| `Transcripts.swift` | The `TranscriptReader` protocol and shared parsing |
| `ClaudeTranscript.swift` / `CodexTranscript.swift` | One reader per assistant |
| `UsageWindowTracker.swift` | The Claude 5-hour block, tokens, limit reports |
| `HookBridge.swift` | Claude Code hook install/uninstall and state files |
| `OverlayController.swift` | The runners, the wall, the click panel |
| `StatusBarController.swift` | Menu bar readout and settings |
| `Sprites.swift` | Pixel art, the contact sheet, the app icon |
| `Localization.swift` | Every user-visible string, English and Korean |

## Adding an animal

Pick a body template, a palette and one distinguishing feature in
`Sprites.swift`, add the emoji to `RunnerSettings.animals`, and add its name to
both languages in `Localization.swift`. Check it with
`./build/VibeCheck --dump-sprites out.png`.

## Adding an assistant

Implement `TranscriptReader` and register it in `Transcripts.reader(for:)`, then
add the binary names to `ProcessMonitor.assistants`. The bar to clear is that
the reader must know a turn is still running while the process sits at 0% CPU
waiting on the API — that is the difference between a runner that means
something and one that lies. Write fixture tests for the tail states the way
`Tests/VibeCheckTests/TranscriptTests.swift` does; detection has been wrong
before and the tests are what keep it fixed.

## Strings

No user-visible string is written inline. Use `L10n.t("English", "한국어")` —
the English wording first, because the README that brings people here is
English. `VIBECHECK_LANG=en` or `=ko` forces one at runtime, which is how
screenshots get taken in either language.

## House rules

- Comments explain *why*, especially where the obvious implementation was
  wrong. Several of them are load-bearing history.
- Don't claim in the README what the code doesn't measure. The usage display
  says "time until reset" because that is what it knows.
