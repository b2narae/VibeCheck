# Command-line reference

VibeCheck is a menu bar app, but the same binary answers a handful of questions
from the terminal. These exist because detection is the part that goes wrong,
and "it looked wrong" is not a bug report you can act on.

The binary lives at `./build/VibeCheck` after `./scripts/build.sh`, or at
`/Applications/VibeCheck.app/Contents/MacOS/VibeCheck` once installed.

## Everyday

### `--install-hooks` / `--uninstall-hooks`

Adds or removes VibeCheck's hooks in `~/.claude/settings.json`. Equivalent to
the menu toggle.

```console
$ /Applications/VibeCheck.app/Contents/MacOS/VibeCheck --install-hooks
hooks installed
```

The file is **merged**, not rewritten: your other settings and anyone else's
hooks are untouched, and a one-time backup is written to
`settings.json.vibecheck-backup` before the first edit. Uninstalling removes
only entries VibeCheck added — including ones left behind under the app's
former name, *Gallop*, so an old install cannot leave a hook pointing at a
binary you no longer have.

Five turn-boundary events are registered: `SessionStart`, `UserPromptSubmit`,
`Notification`, `Stop`, `SessionEnd`. Per-tool events are deliberately **not**
registered — hooks block the session while they run.

### `--hooks-status`

```console
$ ./build/VibeCheck --hooks-status
installed
```

### `--hook`

Not for you to run. This is what the hooks themselves invoke; it reads one
event as JSON on stdin and records the session's phase under
`~/.vibecheck/sessions/<session-id>.json`. It never fails loudly and finishes
in about 10 ms, because whatever it does, the session is waiting on it.

## Diagnosing

### `--debug`

Runs headless and prints every session's state once per poll (1.5 s), plus the
5-hour block. This is the first thing to run when a runner looks wrong.

```console
$ ./build/VibeCheck --debug
claude[24141(VibeCheck)=working 12% [b09e5583-….jsonl] 85021(app)=idle 0% [093ab356-….jsonl]]
usage-block: 12:00–17:00 elapsed=0.60 tokens=16007002
>>> Claude Code @ app finished
```

Each session prints as `pid(project)=state[!] cpu% [log-file]`, where `!` means
it is waiting on you and `no-log` means no transcript could be matched — the
single most useful thing on the line, because a session with no transcript is
judged by CPU alone.

### `--check-session <directory>`

What VibeCheck would read for a session in that working directory, for every
assistant. Use it when a runner behaves but the panel is empty, or vice versa.

```console
$ ./build/VibeCheck --check-session ~/code/myapp
Claude Code: /Users/me/.claude/projects/-Users-me-code-myapp/ab8cacd0-….jsonl
  tail:   awaitingAssistant
  prompt: fix the flaky test in checkout_spec
  answer: I found the race — the fixture and the worker share a clock.
  waiting on: -
Gemini CLI: no transcript reader
Codex CLI: no log found for /Users/me/code/myapp
```

`no log found` for Codex means no rollout recorded that directory **and** was
written within the last three days. That is correct for a directory whose
sessions are all finished; it is a bug if a session is running there now.

### `--check-log <file>` · `--check-prompt <file>` · `--check-detail <file>`

The three transcript questions, against one file. The reader is chosen by path,
so a `/.codex/` path is parsed as a Codex rollout and anything else as a Claude
log.

```console
$ ./build/VibeCheck --check-log ~/.claude/projects/-Users-me-app/abc.jsonl
pendingToolUse

$ ./build/VibeCheck --check-detail ~/.codex/sessions/2026/09/08/rollout-….jsonl
lastResponse: Deploying now.
pendingQuestion: -
pendingTool: approval — git push --force
```

`--check-log` prints one of `turnEnded`, `awaitingAssistant`, `pendingToolUse`,
`awaitingUser`, `unknown`.

### `--check-usage`

The current 5-hour block, computed synchronously.

```console
$ ./build/VibeCheck --check-usage
start:    2026-09-08 12:00
end:      2026-09-08 17:00
elapsed:  0.594
tokens:   16007002
exhausted:false
```

`no active block` means there has been no local Claude activity recently — not
that anything is exhausted. `exhausted` is true only when Claude Code itself
reported the limit; see [usage-window.md](usage-window.md).

## Building assets

### `--dump-sprites <file.png>`

Renders every animal's four gait frames as one contact sheet — 14 rows × 4
columns. **The only capture of this app that contains no session information at
all**, which makes it the one screenshot that is always safe to publish.
`docs/runners.png` is its output.

### `--dump-iconset <directory>`

Renders the ten PNGs macOS wants for an `.icns`. `scripts/make-app.sh` calls
this and pipes the result through `iconutil`, which is why no icon asset is
checked in and the icon cannot drift from the sprites.

## Environment variables

| Variable | Effect |
|---|---|
| `VIBECHECK_LANG` | `en` or `ko`, overriding the system language. How screenshots get taken in either language. |
| `CLAUDE_CONFIG_DIR` | Honoured when locating `projects/`, matching Claude Code. |
| `CODEX_HOME` | Honoured when locating `sessions/`, matching Codex CLI. |

## Files VibeCheck touches

| Path | Access | What |
|---|---|---|
| `~/.claude/projects/**/*.jsonl` | read | Claude transcripts |
| `~/.codex/sessions/**/*.jsonl` | read | Codex rollouts |
| `~/.claude/settings.json` | **write** | only via `--install-hooks` / `--uninstall-hooks` |
| `~/.claude/settings.json.vibecheck-backup` | write | one-time backup before the first edit |
| `~/.vibecheck/sessions/*.json` | write | hook phase reports; pruned after 7 days |
| `UserDefaults` (`dev.lumx.vibecheck`) | write | `overlayEnabled`, `runnerEmoji.<assistant>`, `sound.finish`, `sound.attention` |

No network access of any kind. See [SECURITY.md](../SECURITY.md).
