# Troubleshooting

Start with `./build/VibeCheck --debug`. It prints every session it can see,
once per poll, and most of the answers below are visible in one line of it.

```
claude[24141(VibeCheck)=working 12% [b09e5583-….jsonl] 85021(app)=idle 0% [no-log]]
```

`pid(project)=state cpu% [log]`. **`no-log` is the thing to look for**: a
session with no transcript is judged by CPU alone, which is exactly when
runners misbehave.

---

## No runners at all

**Is the overlay on?** Menu → *Run the animals on screen*. It persists, so it
may be off from a previous session.

**Does `--debug` see your sessions?** If it prints `(no sessions)` while a CLI
is running:

- Sessions must be **interactive**. `claude -p …`, `codex exec …` and
  subcommands like `claude auth status` are deliberately ignored.
- A CLI started **by another session's tools** is ignored on purpose, so an MCP
  server or a script does not raise a phantom runner.
- A new pid is held for **one poll** before it can appear, so anything living
  under ~3 seconds never shows up.

If `--debug` does see them but nothing is drawn, the overlay window is the
problem — see *nothing on the external display* below.

## A runner ran off while the session was still thinking

The signature of a session being judged by **CPU alone**: waiting on the API is
0% CPU, so it looks finished.

- **Gemini CLI** — expected. It writes no readable transcript, so this is a
  known limitation, not a misconfiguration. See the per-assistant table in the
  README.
- **Claude or Codex** — check `--debug` for `no-log` on that session, then run
  `--check-session <its directory>`. If the log cannot be located, that is the
  bug; see the next two entries.

For Claude, turning on **hooks** (menu → *Claude Code hooks*) removes the
guesswork entirely.

## `--check-session` says "no log found" for Codex

A rollout is matched to a running process by the working directory recorded in
its first line, and only rollouts **written within the last 3 days** are
considered.

- If the session was started somewhere else and you `cd`'d, the recorded
  directory is the original one — that is what to pass.
- A session idle for more than three days will not be matched until it writes
  again. Send it a prompt and it reappears.
- `$CODEX_HOME` is honoured; if you set it, VibeCheck needs it set too.

## The panel or menu shows no instruction

The panel reads back as far as **4 MB** from the end of the transcript. A single
turn that produced more tool output than that will genuinely have pushed your
instruction out of reach, and the line shows `-`.

The state of the runner is unaffected — that is read from the newest entries.

## A wall that will not come down

**With hooks** the wall should drop the moment you answer, because the report is
distrusted as soon as the transcript moves past it. If it persists, check
`--check-log <the session's file>`; anything other than `pendingToolUse` or
`awaitingUser` with a wall still up is a bug worth reporting.

**Without hooks** a wall is inferred: a tool call with no result, no CPU
activity, and **10 seconds** elapsed. A tool that is genuinely slow and uses no
CPU — a long network call — will raise a wall it does not deserve. Turning hooks
on is the fix.

## A wall that never appears

- **Codex** raises walls from `*_approval_request` events, which only exist if
  your `approval_policy` actually asks. With `approval_policy = "never"` there
  is nothing to raise.
- **Claude without hooks** infers walls, and only after the 10-second grace.
  With hooks, only `permission_prompt`, `agent_needs_input` and
  `elicitation_dialog` raise one — idle reminders and completion notices
  deliberately do not.
- **Gemini** never raises walls.

## Two sessions in one directory get confused

Sessions are matched to transcripts by session id where one exists, and by
working directory otherwise. Two **Claude** sessions in one directory are
distinguished once hooks are on, because hook reports carry the real session id.

Two **Codex** sessions in one directory will both resolve to the most recently
written rollout. That is a known limitation.

A Claude and a Codex session sharing a directory do **not** interfere — hook
reports are tagged with the assistant that made them.

## Nothing on the external display

The overlay covers the union of all screens and rebuilds when displays change.
Two known rough edges:

- If displays of different sizes are arranged so the union contains regions no
  physical screen covers, a runner positioned there is invisible. Rearranging
  the displays, or turning the overlay off and on, moves them.
- Full-screen apps: the overlay joins all Spaces but sits at floating level, so
  a full-screen app on the same display covers it. The menu bar readout still
  works.

## The tombstone appeared and I am not out of quota

It should not, as of 0.2.0 — it now requires Claude Code to report the limit
itself. If you see one without having been rate-limited, that is a bug: please
include `--check-usage` output.

Conversely, `no active block` is **not** a warning. It means there has been no
local Claude activity recently.

## "Open at login" fails

`SMAppService` only registers a real app bundle. Running `./build/VibeCheck`
directly, or a bundle sitting in `~/Downloads`, will fail. Copy
`VibeCheck.app` to `/Applications` and launch it from there. The alert repeats
this.

## `swift build` fails after a toolchain change

The package asks for tools version `6.0` and builds in Swift 6 language mode.
If SwiftPM misbehaves in another way, `./scripts/build.sh` compiles with plain
`swiftc` and is what ships the app — it also works around a stale
`module.modulemap` in some Command Line Tools installs.

## Reporting a bug

Please include:

1. `./build/VibeCheck --debug` output covering the moment it went wrong.
2. `--check-session <directory>` for the session involved.
3. macOS version, and the CLI's version (`claude --version`, `codex --version`).
4. Whether hooks are on (`--hooks-status`).

**Do not paste transcript contents.** `--debug` prints file names, not
conversations, and `--check-session` prints your instruction and the assistant's
answer — redact those.
