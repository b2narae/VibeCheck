# Gallop 🐎

**Fire off a prompt, go do something else. When the animal stops running, your AI is done.**

You know the loop. You type the prompt. You tab away. Ten seconds later you tab
back — still going. Tab away. Tab back. Still going. You end up babysitting the
thing you delegated so you wouldn't have to babysit it.

Gallop puts a tiny pixel animal on your screen that runs *only while your coding
assistant is actually working*. Now you just glance. Still running? Still working.
Stopped? Go look. That's the whole product.

![The runners](docs/runners.png)

```bash
git clone https://github.com/b2narae/Gallop.git && cd Gallop
./scripts/make-app.sh && cp -R build/Gallop.app /Applications/ && open /Applications/Gallop.app
```

That's it. No config file, no API key, no sign-in. It finds your sessions by
itself. Works with **Claude Code**, **Gemini CLI**, and **Codex CLI**.

---

## What you actually get

**🐎 One animal per terminal.** Running three sessions at once? You get three
animals — a horse, a turtle, a tiny dinosaur — each one bound to a specific
terminal. Suddenly "which of my five tabs is still cooking?" is a question you
answer by looking, not by clicking through tabs.

**🧱 A wall means it wants something from you.** When Claude stops to ask for
permission, or wants an API key, or asks you a question, a brick wall drops in
front of that animal and it halts, shoving against the wall until you come back.
No more discovering ten minutes later that it's been politely waiting for a yes.

**🖱️ Click an animal, see its job.** Hover one and click — it tells you which
project it's in and what you actually asked it to do. Handy when three animals
are running and you've forgotten which is which.

**📉 Height = how much Claude you have left.** Claude's usage limit refreshes in
5-hour blocks. A fresh block puts your runner up near the top of the screen, and
it drifts lower as you burn through the window. Running along the bottom? Wrap it
up, the reset is coming.

**🔔 Sounds you choose.** Pick any macOS system sound for "done" and for "needs
you" — or silence. It previews as you pick.

**💤 It gets out of the way.** Clicks pass straight through the animals, so
nothing blocks the app you're working in. No Dock icon. Turn the overlay off
entirely and keep just the menu bar readout if you want.

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

## Make it exact (one click)

Out of the box, Gallop works everything out by watching your machine — no setup
required. But if you want it to be *precise*, flip on **"Claude Code 훅 연동"** in
the menu.

That lets Claude Code tell Gallop directly when a turn starts, when it ends, and
when it's stuck waiting on you — instead of Gallop inferring it. Permission
prompts raise the wall the instant they appear.

```bash
/Applications/Gallop.app/Contents/MacOS/Gallop --install-hooks     # or use the menu
/Applications/Gallop.app/Contents/MacOS/Gallop --uninstall-hooks
```

It merges into `~/.claude/settings.json` without touching your other settings or
hooks, and backs the file up first. Turning it off removes only what Gallop
added.

---

## Fair questions

**Will this slow my machine down?** It's a single native Swift binary — no
Electron, no runtime, no dependencies. It checks your process list a couple of
times a second and draws some pixels.

**Does it phone home?** No. There is no network code in this app at all. It reads
your local session files and that's the end of it.

**Does the hook slow down Claude?** Hooks block Claude while they run, so Gallop
registers only turn-boundary events (not per-tool ones) and its hook finishes in
about 10 ms.

**I don't use Claude Code.** Gemini CLI and Codex CLI runners work too. The
usage-window height and the wall are Claude-specific for now.

**Something looks wrong.** Run `./build/Gallop --debug` — it prints what it thinks
each session is doing, once per poll.

---

## How it actually works

<details>
<summary>For the curious (click to expand)</summary>

Gallop polls the process list every 1.5 seconds and tracks each `claude` /
`gemini` / `codex` process by PID, skipping resident helpers like daemons and pty
hosts. Working directories come from libproc (`proc_pidinfo`), so no subprocess
is spawned per poll.

**With hooks installed**, `SessionStart`, `UserPromptSubmit`, `Notification`,
`Stop` and `SessionEnd` each run `Gallop --hook`, which records that session's
phase under `~/.gallop/sessions/`. Only genuine "blocked on you" notifications
raise the wall — idle reminders and completion notices don't. Interrupting a turn
with Esc fires no `Stop` hook, so a "working" report whose transcript has been
quiet for three minutes is distrusted.

**Without hooks**, two signals are combined:

1. **CPU**, summed across the session's child processes, so long builds and test
   runs count as work.
2. **Turn state from the transcript**, read from the last entry's `stop_reason`.
   A turn is over only on `end_turn` (or `stop_sequence` / `max_tokens` /
   `refusal`); `tool_use` means more is coming, so the session stays "working"
   even while the process sits quietly waiting on the API. This matters more than
   it sounds: assistant text and thinking blocks are logged *mid-turn* too, so
   judging by content alone marks a busy session finished dozens of times per
   turn, and runners keep dashing off and re-entering.

The 5-hour window is estimated the way [ccusage](https://github.com/ryoppippi/ccusage)
does it — first activity after the previous block ended, floored to the hour, plus
five hours. It can differ from the server's own reset by a few minutes.

</details>

---

## Add your own animal

Genuinely a two-minute PR. Sprites are drawn in code — pick one of six body
templates, give it a palette and a distinguishing feature, and you're done. It's
all in [`Sources/Gallop/Sprites.swift`](Sources/Gallop/Sprites.swift).

```swift
"🦔": Species(.small, body: (0.55, 0.42, 0.32), accent: (0.30, 0.24, 0.18), accessory: .spikes),
```

Preview your work with `./build/Gallop --dump-sprites out.png`. Requires macOS 13+
and the Xcode Command Line Tools.

[한국어 README](README.ko.md) · MIT License
