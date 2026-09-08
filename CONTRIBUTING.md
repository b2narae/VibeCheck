# Contributing

Bug reports, animals and assistants all welcome. By taking part you agree to the
[code of conduct](CODE_OF_CONDUCT.md), which is short and amounts to "be
decent". Issues and pull requests are fine in English or Korean.

VibeCheck is a single native Swift binary with no dependencies. macOS 13+ and
the Xcode Command Line Tools are all you need.

```bash
git clone https://github.com/b2narae/VibeCheck.git && cd VibeCheck
swift test              # 66 tests, well under a second
./scripts/make-app.sh   # build the .app and try it
open build/VibeCheck.app
```

Two builds exist and both must stay green — CI runs both on every push and
pull request (`.github/workflows/ci.yml`):

- **`swift build` / `swift test`** — SwiftPM, Swift 6 language mode. This is the
  one CI and contributors reach for first. The manifest asks for tools version
  `6.0`, not `6.1`, because Xcode 16.0–16.2 refuses to parse `6.1` outright; the
  language mode is unaffected.
- **`./scripts/build.sh`** — plain `swiftc`, which is what ships the app. It
  exists because some Command Line Tools installs have a broken SwiftPM
  manifest API, and it works around a stale `module.modulemap` when it finds
  one.

Read [docs/architecture.md](docs/architecture.md) before changing how sessions
are detected. It explains the priority order between hooks, the transcript and
CPU, and why each fallback is shaped the way it is.

## Where things are

| File | What it does |
|---|---|
| `ProcessMonitor.swift` | Finds sessions, decides idle/working/blocked. The only component that forms an opinion. |
| `ProcessList.swift` | libproc + sysctl process table, CPU sampling |
| `Transcripts.swift` | The `TranscriptReader` protocol, the reverse line walker, shared parsing |
| `ClaudeTranscript.swift` / `CodexTranscript.swift` | One reader per assistant |
| `UsageWindowTracker.swift` | The Claude 5-hour block, tokens, limit reports |
| `HookBridge.swift` | Claude Code hook install/uninstall and state files |
| `OverlayController.swift` | The runners, the wall, the click panel |
| `StatusBarController.swift` | Menu bar readout, settings, "Open at login" |
| `SessionSummary.swift` | The lines the menu and the panel both show, cached per (file, mtime) |
| `Sprites.swift` | Pixel art, the contact sheet, the app icon |
| `Localization.swift` | Every user-visible string, English and Korean |

## Adding an animal

Genuinely a two-minute PR.

1. Add a `Species` in `Sprites.swift`: one of six body templates, a palette, and
   one distinguishing feature.
2. Add the emoji to `RunnerSettings.animals`.
3. Add its name to both languages in `Localization.swift`.

`swift test` checks all three: a species missing its art renders as the horse,
and one missing a name shows as "runner". Both are caught rather than shipped.

```swift
"🦔": Species(.small, body: (0.55, 0.42, 0.32), accent: (0.30, 0.24, 0.18), accessory: .spikes),
```

Check it with `./build/VibeCheck --dump-sprites out.png`. Sprites are 22×14
pixels and all face left on a shared ground row, so a new species has to be
recognisable from its silhouette and one feature.

## Adding an assistant

Implement `TranscriptReader` and register it in `Transcripts.reader(for:)`, then
add the binary names to `ProcessMonitor.assistants`.

**The bar to clear**: the reader must know a turn is still running while the
process sits at 0% CPU waiting on the API. That is the difference between a
runner that means something and one that lies, and it is why Gemini CLI is
still CPU-only. If a CLI records nothing that distinguishes "thinking" from
"finished", say so in the README's per-assistant table rather than shipping a
runner that runs off mid-turn.

Write fixture tests for every tail state, the way
`Tests/VibeCheckTests/TranscriptTests.swift` does. Detection has been wrong four
separate times and the tests are what keep each fix in place.

## Working on the overlay without real sessions

```bash
./scripts/demo-sessions.sh up      # three staged sessions, one at a wall
./scripts/demo-sessions.sh down    # stop and clean up
```

This stages fake assistant processes and hand-written transcripts in a
throwaway directory, then launches VibeCheck against it with `CLAUDE_CONFIG_DIR`
and `CODEX_HOME` pointed there. Nothing reads or writes your real `~/.claude` or
`~/.codex`, no quota is spent, and no real prompt is ever on screen — which is
also what makes it the right way to take a screenshot. `shot` captures, and
prints what to check before publishing.

It is a useful test of the readers in itself: the runners you see are driven
entirely by files the script wrote, so if one behaves oddly, the input is right
there to read.

## Tests

```bash
swift test
```

`Tests/VibeCheckTests/` holds fixture-driven tests: no network, no sleeping, no
dependence on what happens to be running on your machine. They build transcripts
in a temporary directory and assert on what the readers make of them.

Several encode a bug that actually happened — a mid-turn text block being read
as a finished turn, an approval already answered still raising a wall, a rollout
whose day folder is older than the session. If you are changing detection and a
test fails, read the comment above it before changing the expectation.

## Strings

No user-visible string is written inline. Use `L10n.t("English", "한국어")` —
the English wording first, because the README that brings people here is
English. `VIBECHECK_LANG=en` or `=ko` forces one at runtime, which is how
screenshots get taken in either language.

## Performance

"It is not heavy" is part of what this app claims, so a few things are
deliberate and worth preserving:

- **No subprocesses in the polling path.** Sessions come from libproc, not
  `ps`. Full argv is fetched only for processes that could be an assistant.
- **Transcripts are append-only**, so nothing is ever re-read. The usage scan
  keeps a per-file offset; `SessionSummary` and the tail classifier cache on
  mtime.
- **Only the lines actually examined are decoded.** `forEachLineFromEnd` exists
  because splitting a multi-megabyte tail into strings up front, and worse
  re-splitting it with a growing window, both measured badly.

If you change any of these, measure it. The numbers that motivated them are in
[CHANGELOG.md](CHANGELOG.md) and the comments themselves.

## House rules

- Comments explain *why*, especially where the obvious implementation was
  wrong. Several of them are load-bearing history — don't tidy them away.
- Don't claim in the README what the code doesn't measure. The usage display
  says "time until reset" because that is what it knows; see
  [docs/usage-window.md](docs/usage-window.md) for how that lesson was learned.
- If a change makes a README sentence false, fix the sentence in the same
  commit.
