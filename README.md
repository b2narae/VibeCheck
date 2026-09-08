# VibeCheck 🐎

[![CI](https://github.com/b2narae/VibeCheck/actions/workflows/ci.yml/badge.svg)](https://github.com/b2narae/VibeCheck/actions/workflows/ci.yml)

**Fire off a prompt, go do something else. When the animal stops running, your AI is done.**

You know the loop. You type the prompt. You tab away. Ten seconds later you tab
back — still going. Tab away. Tab back. Still going. You end up babysitting the
thing you delegated so you wouldn't have to babysit it.

VibeCheck puts a tiny pixel animal on your screen that runs *only while your coding
assistant is actually working*. Now you just glance. Still running? Still working.
Stopped? Go look. That's the whole product.

![The runners](docs/runners.png)

```bash
git clone https://github.com/b2narae/VibeCheck.git && cd VibeCheck
./scripts/make-app.sh && cp -R build/VibeCheck.app /Applications/ && open /Applications/VibeCheck.app
```

That's it. No config file, no API key, no sign-in. It finds your sessions by
itself. Works with **Claude Code**, **Codex CLI**, and **Gemini CLI**.

---

## What you actually get

**🐎 One animal per terminal.** Running three sessions at once? You get three
animals — a horse, a turtle, a tiny dinosaur — each one bound to a specific
terminal. Suddenly "which of my five tabs is still cooking?" is a question you
answer by looking, not by clicking through tabs.

**🧱 A wall means it wants something from you.** When Claude stops to ask for
permission, or wants an API key, or asks you a question — or when Codex asks to
approve a command — a brick wall drops in front of that animal and it halts,
shoving against the wall until you come back. And the moment you answer in the
terminal, the wall comes down — it tracks the session's actual transcript, not
just the notification that raised it.

**🖱️ Click an animal, see where it stands.** Hover one and click — which
project it's in, what you asked, and the latest thing it said back. If it's
stopped at the wall, the panel shows the *actual* question it's asking or the
exact tool call it wants permission for (`Bash — git push …`). The wall itself
is clickable too.

**🐾 The menu bar is a headcount.** The status item shows one animal per
running session — blocked ones lead with their wall, like 🧱🐕. Hover a
session's row in the menu for the same details as clicking its runner.

**⏳ Height = time left before Claude's limit resets.** Claude's usage limit
refreshes in 5-hour blocks. A fresh block puts your runner up near the top of
the screen, and it drifts lower — and fades — as that block runs down. Running
along the bottom? Wrap it up, the reset is coming. The menu line spells it out,
and adds the one number that is actually measured: the tokens this block has
spent.

> This is a clock, not a fuel gauge. It says how close the reset is, not how
> much of your quota is gone — nothing published locally can tell us that. The
> one exception is the tombstone: if Claude itself reports that the limit is
> reached, the runner freezes as a pixel-art grave until the reset it named.

**🔔 Sounds you choose.** Pick any macOS system sound for "done" and for "needs
you" — or silence. It previews as you pick.

**💤 It gets out of the way.** Clicks pass straight through the overlay
everywhere except the few pixels of a runner or its wall, so nothing blocks the
app you're working in. No Dock icon. It honours "Reduce motion" — the animals
hold still and keep saying everything they say. Turn the overlay off entirely
and keep just the menu bar readout if you want. There's an **Open at login**
toggle in the menu.

---

## Meet the runners

Pick your favorite per assistant, or set it to 🎲 and let every terminal surprise
you. Each one is a hand-drawn pixel sprite with a real four-frame run cycle —
legs actually move.

| | | | |
|---|---|---|---|
| 🐎 Horse | 🦄 Unicorn | 🐫 Camel | 🐕 Dog |
| 🐈 Cat | 🐇 Rabbit | 🐢 Turtle | 🦖 T-Rex |
| 🐖 Pig | 🐄 Cow | 🦌 Deer | 🦘 Kangaroo |
| 🐆 Cheetah | 🐿️ Squirrel | | |

Yes, the turtle runs at the same speed as the cheetah. Life is unfair.

---

## What works with which assistant

VibeCheck reads whatever each CLI writes down. That is not the same amount for
all three, so here is the honest table.

| | Claude Code | Codex CLI | Gemini CLI |
|---|---|---|---|
| A runner per session | ✅ | ✅ | ✅ |
| Knows a turn is running while the API is thinking | ✅ | ✅ | ⚠️ CPU only |
| 🧱 Wall when it needs you | ✅ | ✅ approvals | ❌ |
| Click for prompt / answer / pending call | ✅ | ✅ | ❌ |
| Height = time to reset | ✅ | ❌ | ❌ |
| Hooks for exact turn boundaries | ✅ | ❌ | ❌ |

**Why the Gemini column is thin:** the other two write a session transcript we
can read, so VibeCheck knows a turn is still going even while the process sits
at 0% CPU waiting on the API. Gemini CLI doesn't, so its runner is judged by CPU
alone — which means a Gemini session that is only *waiting* can look finished.
If you know where Gemini CLI records its turns, that is a small and very welcome
PR.

---

## Make it exact (one click)

Out of the box, VibeCheck works everything out by watching your machine — no setup
required. But if you want it to be *precise*, flip on **"Claude Code hooks"** in
the menu.

That lets Claude Code tell VibeCheck directly when a turn starts, when it ends, and
when it's stuck waiting on you — instead of VibeCheck inferring it. Permission
prompts raise the wall the instant they appear.

```bash
/Applications/VibeCheck.app/Contents/MacOS/VibeCheck --install-hooks     # or use the menu
/Applications/VibeCheck.app/Contents/MacOS/VibeCheck --uninstall-hooks
```

It merges into `~/.claude/settings.json` without touching your other settings or
hooks, and backs the file up first. Turning it off removes only what VibeCheck
added.

Codex needs no equivalent: its rollout log already records `task_started` and
`task_complete` outright, so its turns are exact without any setup.

---

## Fair questions

**Will this slow my machine down?** It's a single native Swift binary — no
Electron, no runtime, no dependencies. It reads the process table through
libproc a couple of times a second (no subprocesses) and draws some pixels.
Transcripts are append-only, so each one is parsed once and after that only from
wherever the last pass stopped.

**Does it phone home?** No. There is no network code in this app at all. It reads
your local session files and that's the end of it.

**Does the hook slow down Claude?** Hooks block Claude while they run, so VibeCheck
registers only turn-boundary events (not per-tool ones) and its hook finishes in
about 10 ms.

**It shows my prompts on screen.** It does — that's the point of the click
panel, and it's worth knowing before you screen-share or record. Nothing leaves
your machine, but the panel will happily render whatever you typed.

**Something looks wrong.** Run `./build/VibeCheck --debug` — it prints what it
thinks each session is doing, once per poll. `--check-session <dir>` shows which
transcript it picked for a working directory and what it read out of it, and
`--check-usage` prints the current 5-hour block.

---

## How it actually works

<details>
<summary>For the curious (click to expand)</summary>

VibeCheck reads the process table every 1.5 seconds through libproc and tracks
each `claude` / `codex` / `gemini` process by PID — no subprocess is spawned, and
full command lines are only fetched for the handful of processes whose name
could belong to an assistant. Only interactive terminal sessions count:
resident helpers (daemons, pty hosts), one-shot invocations (`claude auth
status`, `claude -p …`, `codex exec …`), the npm shim that launches the real
Codex binary, and CLIs spawned from another session's own tools are all skipped,
and a new pid must survive two polls before it may appear — so a dev server
shelling out to `gemini auth status` every few seconds doesn't flood your screen
with phantom runners. Working directories come from libproc (`proc_pidinfo`).

CPU is sampled as consumed CPU *time* per process tree, differenced between
polls, which is what "busy right now" actually means; long builds and test runs
count as work because child processes are summed in.

**With hooks installed**, `SessionStart`, `UserPromptSubmit`, `Notification`,
`Stop` and `SessionEnd` each run `VibeCheck --hook`, which records that session's
phase under `~/.vibecheck/sessions/`. Only genuine "blocked on you" notifications
raise the wall — idle reminders and completion notices don't. Hook reports are
trusted only while the transcript agrees with them: interrupting a turn with Esc
fires no `Stop` hook, so a "working" report whose transcript has been quiet for
three minutes is distrusted, and approving a permission prompt fires no hook
either, so an "attention" report is dropped as soon as the transcript moves past
it. Hooks carry the session's real id, which pins log lookups to the right
file when several sessions share one project, and the assistant that reported
them, so a Claude session never hands its state to a Codex session running in
the same folder.

**Without hooks**, two signals are combined:

1. **CPU**, summed across the session's child processes.
2. **Turn state from the transcript**, which is where the two supported
   transcripts differ:
   - **Claude Code** — the last entry's `stop_reason`. A turn is over only on
     `end_turn` (or `stop_sequence` / `max_tokens` / `refusal`); `tool_use` means
     more is coming, so the session stays "working" even while the process sits
     quietly waiting on the API. This matters more than it sounds: assistant text
     and thinking blocks are logged *mid-turn* too, so judging by content alone
     marks a busy session finished dozens of times per turn, and runners keep
     dashing off and re-entering.
   - **Codex CLI** — `~/.codex/sessions/**/rollout-*.jsonl` states it outright:
     `task_started` opens a turn, `task_complete` and `turn_aborted` close it,
     and `*_approval_request` means it is blocked on you. The scan runs backwards
     and stops at the first decisive event, so an approval that has since been
     answered is buried under the tool output that followed it — and the constant
     `token_count` chatter is skipped rather than mistaken for progress. A running
     session is matched to its rollout by the working directory its `session_meta`
     recorded.

The click panel's details come from the transcript too: the most recent
assistant text is the "latest response", and an unanswered tool call at the end
of the log is the pending question (for Claude's `AskUserQuestion`, the question
text itself), the tool call awaiting permission, or the command Codex wants
approved.

The 5-hour block is estimated the way [ccusage](https://github.com/ryoppippi/ccusage)
does it — first activity after the previous block ended, floored to the hour, plus
five hours. It can differ from the server's own reset by a few minutes, and it
gets recomputed the moment a session starts a turn rather than on a timer, so a
runner is never drawn against a stale block. Token counts exclude cache *reads*:
the same cached prefix is re-read on every request, and counting it would measure
how long your conversation is rather than what the block spent.

</details>

---

## Add your own animal

Genuinely a two-minute PR. Sprites are drawn in code — pick one of six body
templates, give it a palette and a distinguishing feature, and you're done. It's
all in [`Sources/VibeCheck/Sprites.swift`](Sources/VibeCheck/Sprites.swift).

```swift
"🦔": Species(.small, body: (0.55, 0.42, 0.32), accent: (0.30, 0.24, 0.18), accessory: .spikes),
```

Preview your work with `./build/VibeCheck --dump-sprites out.png`.

## Building and testing

Requires macOS 13+ and the Xcode Command Line Tools.

```bash
./scripts/build.sh      # the binary, via swiftc
./scripts/make-app.sh   # the .app bundle (renders its own icon)
swift test              # the detection tests
```

`swift build` works too. See [CONTRIBUTING.md](CONTRIBUTING.md).

[한국어 README](README.ko.md) · MIT License
