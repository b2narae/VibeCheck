# Gallop 🐎💨

**A little animal runs across your screen while your coding assistant works.**

Gallop is a tiny macOS menu bar app that shows, at a glance, whether Claude Code,
Gemini CLI, or Codex CLI is actually working. Kick off a task, switch to another
window — as long as the animal is running, your assistant is still busy. When it
stops, the work is done.

No plugins, no hooks, no configuration. Launch it and it finds your sessions.

[한국어 README](README.ko.md)

![The 14 runners, each with a 4-frame gait](docs/runners.png)

## What it shows

**One animal per terminal.** Most people keep several assistant sessions open.
Gallop tracks each one separately and gives it its own animal, so you can tell
which terminal is busy just by looking. The animal sticks with that session for
its lifetime.

**Runners actually run.** Each animal is a hand-built pixel sprite with a
four-frame gait — reach, pass, gather, pass — moving forward only, no floating.

**Click an animal to see its task.** Hovering a runner makes just that spot
clickable (everywhere else stays click-through, so it never gets in your way).
Clicking pops up the project, the current state, and the most recent instruction
you gave that session.

**A wall means it needs you.** When Claude stops to ask for permission, an
environment variable, a key, or an answer, a brick wall appears in front of that
animal and it halts, nudging against the wall until you respond.

**Height tracks Claude's 5-hour usage window.** Claude's usage limit refreshes in
5-hour blocks. A Claude runner starts at the top of the screen when a fresh block
begins and sinks lower as the block is consumed. When it's running along the
bottom, a reset is near. The menu shows the exact time remaining.

**Sounds you pick.** Choose any of 14 macOS system sounds — or silence —
separately for "task finished" and "needs input", with a preview when selecting.

The menu bar icon itself summarizes everything: a galloping animal while work is
happening, 🧱 when a session is blocked on you, 🐴 when sessions are idle, 💤 when
nothing is running.

## How detection works

Gallop polls the process list every 1.5 seconds and tracks `claude` / `gemini` /
`codex` processes per PID, skipping resident helpers like daemons and pty hosts.
Each session's working directory comes from libproc (`proc_pidinfo`), so no
subprocesses are spawned per poll.

Deciding "is it working?" combines two signals:

1. **CPU**, summed over the session's child processes, so a long build or test
   run counts as work.
2. **Turn state from the session log** (Claude), read from the last entry's
   `stop_reason`. A turn is over only on `end_turn` (or `stop_sequence` /
   `max_tokens` / `refusal`); `tool_use` means another block is still coming, so
   the session stays "working" even while the process sits quietly waiting on
   the API. This matters because assistant text and thinking blocks are logged
   mid-turn as well — judging by content alone marks a working session finished
   dozens of times per turn, and runners keep dashing off and re-entering.

**Needs-input detection**: an idle session whose log ends with a `tool_use` that
has no result yet is waiting on you. Logs are only re-read when their mtime
changes. (Known limitation: a long-running tool that uses almost no CPU can
occasionally read as a permission prompt.)

The 5-hour window is estimated the same way [ccusage](https://github.com/ryoppippi/ccusage)
does it — the block start is the first activity after the previous block ended,
floored to the hour, plus five hours. It can differ from the server's own reset
by a few minutes.

Everything is read locally from your own machine. Gallop makes no network
requests and sends nothing anywhere.

## Install

Requires macOS 13+ and a Swift toolchain (Xcode Command Line Tools).

```bash
git clone https://github.com/b2narae/Gallop.git
cd Gallop
./scripts/make-app.sh
open build/Gallop.app
```

`scripts/make-app.sh` builds `build/Gallop.app`, a menu-bar-only bundle (no Dock
icon). Move it to `/Applications` if you want to keep it around. To run it
without building a bundle, use `./scripts/build.sh && ./build/Gallop`, or
`swift build` if SwiftPM works on your setup.

Handy flags while developing:

```bash
./build/Gallop --debug                  # print detected sessions each poll
./build/Gallop --dump-sprites out.png   # render the sprite contact sheet
```

## Roadmap

- [ ] Launch at login (SMAppService)
- [ ] Claude Code hooks integration for exact start/stop signals
- [ ] Notification Center alerts naming the finished project
- [ ] Localized UI (the menus are currently Korean)
- [x] Pixel-art sprite runners
- [x] Per-session (per-project) runners

Contributions are welcome — new animals are just a palette and a few pixels in
`Sources/Gallop/Sprites.swift`.

## License

MIT
