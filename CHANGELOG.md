# Changelog

All notable changes to VibeCheck. Dates are the day the work landed on `main`.
This project follows [Semantic Versioning](https://semver.org/); the version
lives in `scripts/make-app.sh` and is stamped into the app bundle.

## [0.2.0] — 2026-09-08

The release that made the display honest and gave Codex CLI real support.

### Changed — the usage display says what it measures

The runner's height and fade were presented as "how much Claude you have left"
while the code drew **how much of the 5-hour block had elapsed**. Two people at
the same height could have spent 2% and 98% of their quota. Nothing published
locally can tell us the quota, so the display is now named for what it is:
**time until the limit resets**.

- The menu line reads `Claude 5-hour block — 2h 14m until reset (17:00)`.
- It also shows **tokens spent in this block**, the one quantity that is
  actually counted. Never as a percentage of a limit nobody publishes.
- Token counts **exclude cache reads**. The same cached prefix is re-read on
  every request — 5.7 billion of them against 19 million real input/output
  tokens in one day of measured use — so counting them would measure how long
  your conversation is, not what the block spent.

### Fixed — the tombstone appeared at the best moment, not the worst

It fired whenever no active block was detected, which is what happens **right
after a break** — when you have the most left. It now waits for Claude Code to
report the limit itself (`isApiErrorMessage` carrying `usage limit
reached|<epoch>`) and uses the reset time the server named. Verified against a
real transcript in which 15 lines contained that marker text without being
reports; none raised the tombstone.

### Added — Codex CLI is supported for real

Codex sessions were judged by CPU alone. A session waiting on the API is at 0%
CPU, so it looked finished: the runner ran off screen and the completion sound
fired mid-turn, breaking the product's only promise on two of three assistants.

Codex's rollout log states turn boundaries outright, so it is now read the way
Claude's transcript is — and needs no setup to be exact, where Claude needs
hooks.

- `task_started` opens a turn; `task_complete` and `turn_aborted` close it.
- `*_approval_request` raises the wall; approving it lowers the wall as soon as
  the tool output that follows lands.
- Click details (instruction, last answer, pending command) now work for Codex.
- A running session is matched to its rollout by the working directory its
  `session_meta` recorded.

### Added — the app speaks the reader's language

Every menu item, panel line and alert follows the system language, English or
Korean. The README that brings people here is English; the menu was not.
`VIBECHECK_LANG=en|ko` forces one, which is how screenshots get taken.

### Added — the conditions for a tool you leave running

- **Open at login** (SMAppService).
- An **app icon**, rendered at build time from the same pixel-art code as the
  runners, so no binary asset is checked in and the icon cannot drift.
- **Multi-display support**: the overlay spans every attached screen and
  follows displays being plugged in or removed. It used to live on whichever
  screen was main when it first opened.
- **Reduce Motion** is honoured: the animals hold still and keep saying
  everything they say.
- Lanes scale with screen height (4–8) instead of a fixed 4.

### Fixed

- A hook report is now tagged with the assistant that made it, so a Claude
  session no longer hands its state to a Codex session in the same directory.
- A failed working-directory lookup is no longer cached for the life of the
  session. One transient `proc_pidinfo` failure used to leave a session with no
  project name, no transcript and no wall, permanently.
- Long-running Codex sessions kept their transcript. Rollouts live under the
  date a session *started*; looking only in the newest three day folders lost
  1 session in 10 (measured over 106 real sessions, one of them running four
  days). Candidates are chosen by file mtime now.

### Performance

| | Before | After |
|---|---|---|
| Process listing | `/bin/ps` spawned 40×/min | libproc syscalls, no subprocess |
| CPU signal | `ps` lifetime decaying average | consumed CPU time differenced per poll |
| Usage scan (1 day of history) | 18.5 s, every minute, whole files | 1.1 s cold, then only appended bytes |
| Opening the menu (5 sessions) | 173 ms every time | 47 ms cold, 0 ms cached |
| Unresolvable session lookup | every 1.5 s | 15 s backoff — 0.34% → 0.014% of a core |

The transcript readers walk lines backwards from the end of the tail and decode
only the lines they examine. Because that is cheap, the search window could widen
to 4 MB, so the panel now answers "what did you ask it" for long tool-heavy
turns — on a real 34 MB rollout the last instruction sat 2.75 MB from the end
and used to show a dash.

### Developer experience

- `swift build` **worked for the first time**: the package failed with four
  Swift 6 concurrency errors, which is the first command a contributor runs.
  Both builds are clean in Swift 6 language mode with zero warnings.
- **66 tests** over the detection logic, which had been corrected four times
  with no regression net at all.
- **CI** runs both builds, the tests, the app bundle and the dev flags on every
  push and pull request.
- The manifest asks for tools `6.0` rather than `6.1`, which Xcode 16.0–16.2
  refuses to parse. The Swift 6 language mode is unaffected.
- New dev flags: `--check-session`, `--check-detail`, `--check-usage`.
- [`CONTRIBUTING.md`](CONTRIBUTING.md), [`SECURITY.md`](SECURITY.md) and
  [`docs/`](docs/) were written.

## [0.1.0] — 2026-08-10 … 2026-08-17

The first working version, developed over three days.

### Added

- **2026-08-10** — A menu bar app that recognises **Claude Code**, **Gemini
  CLI** and **Codex CLI** sessions and runs one animal per working session.
  Hand-drawn pixel sprites with a real four-frame gait, six body templates and
  14 species. A **brick wall** drops in front of a session that wants your
  input. Runner **height** encodes the Claude 5-hour block. Separate,
  previewable **sounds** for "finished" and "needs you". Clicking a runner shows
  what its session was asked.
- **2026-08-11** — **Claude Code hook integration**, merged into
  `~/.claude/settings.json` with a backup and removable again. Only
  turn-boundary events are registered, so hooks never hold a turn up. Opened
  under the **MIT licence** with an English README. Renamed from **Gallop** to
  **VibeCheck**; hooks left behind under the old name are recognised and
  cleaned up.
- **2026-08-17** — The menu bar became a **headcount**, one animal per session
  with blocked ones behind their wall. Clicking a runner shows the *actual*
  pending question or the tool call awaiting permission. Runners **fade** as the
  block runs down and freeze as a **tombstone** when it is spent.

### Fixed

- Turn completion is judged by `stop_reason`, not by whether the last entry had
  text. Assistant text and thinking blocks are written mid-turn, so judging by
  content marked busy sessions finished dozens of times per turn and runners
  kept dashing off and re-entering.
- One-shot invocations (`claude auth status`, `claude -p …`) and CLIs spawned
  by another session's own tools no longer raise runners.
- A wall no longer lingers after you have answered.

[0.2.0]: https://github.com/b2narae/VibeCheck/releases/tag/v0.2.0
[0.1.0]: https://github.com/b2narae/VibeCheck/releases/tag/v0.1.0
