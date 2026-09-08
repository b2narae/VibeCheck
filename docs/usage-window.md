# The 5-hour block: what the height actually means

Short version: **it is a clock, not a fuel gauge.** The runner's height tells
you how close Claude's limit reset is. It does not tell you how much of your
quota you have spent, and it never did — the display just used to claim
otherwise.

## What went wrong

Until 0.2.0 the README, the brief and the menu all described the runner's
height and fade as "how much Claude you have left". The code drew this:

```swift
elapsedFraction = (now - blockStart) / 5 hours
altitude        = bottom + (top - bottom) * (1 - elapsedFraction)
```

That is elapsed time. Two people whose runners sat at the same height could
have spent 2% and 98% of their allowance. The picture was fine; the label was
false.

The tombstone was worse. It was drawn whenever no block was active:

```swift
isExhausted = (usageWindow == nil)      // "no active block"
```

But `currentWindow()` returns `nil` when there has been **no recent activity** —
which is what happens after a break, when you have the *most* left. And because
the tracker only recomputed once a minute, starting a fresh session could show a
grave for up to a minute before the new block was noticed. The one screen that
was supposed to mean "you are out" appeared, in practice, only when you were
not.

## What it says now

**Height and fade** encode time until the reset, and are named that way
everywhere. The menu spells it out rather than leaving you to read a picture:

```
⏳ Claude 5-hour block — 2h 14m until reset (17:00) · 16.0M tokens
```

**The token count is the one measured quantity**, so it is shown as a plain
number and never as a percentage. Nobody publishes the per-plan limits, so
"73% used" would be a number we made up.

**The tombstone quotes Claude instead of guessing.** Claude Code records hitting
the limit as an API error entry carrying the server's own reset time:

```
"isApiErrorMessage":true … "Claude AI usage limit reached|<epoch>"
```

Only that raises the grave, and the menu then shows the reset time Claude named:

```
🪦 Claude usage limit reached — resets 17:00
```

The `isApiErrorMessage` guard is load-bearing. In one real day of transcripts,
**15 lines contained the marker text** without being reports — they were tool
calls from a session that had been asked to grep for that very string. None of
them raised the tombstone; there is a regression test built from exactly that
case.

## Why tokens exclude cache reads

Four token counts appear in a transcript. Measured over one working day here:

| Field | Tokens | Counted? |
|---|---|---|
| `input_tokens` | 163,763 | ✅ |
| `output_tokens` | 18,822,064 | ✅ |
| `cache_creation_input_tokens` | 78,333,975 | ✅ |
| `cache_read_input_tokens` | 5,678,432,745 | ❌ |

Cache reads are the same cached prefix re-read on **every** request. They
outnumber real input and output tokens roughly 300:1 and grow with how long a
conversation is, not with how much work it did. Including them turned the
counter into a measure of conversation length: 828 M against the 16 M of actual
spend. So the number reported is input + output + cache creation.

## How the block is estimated

The same approach as [ccusage](https://github.com/ryoppippi/ccusage):

1. Collect message timestamps from `~/.claude/projects/**/*.jsonl` over the last
   24 hours, deduplicated to the minute.
2. Walk forward. Whenever an entry falls 5 hours or more after the current block
   started, a new block starts at that entry, **floored to the hour**.
3. The block runs 5 hours from there. If that end is in the past, no block is
   active.

This is an estimate. It can differ from the server's own reset by a few minutes,
which is why the tombstone prefers the reset time Claude reports whenever one
exists.

The tracker recomputes every 60 seconds **and immediately whenever a session
starts a turn**, so the first runner after a break is drawn against the block
that just began rather than the absence of one.

## Reading it as a user

| What you see | What it means |
|---|---|
| Runner near the top, bright | The block started recently. |
| Runner sinking, fading | The reset is approaching. |
| Runner along the bottom | Wrap up; the reset is close. |
| 🪦 tombstone | Claude reported the limit reached. The menu has the reset time. |
| No block in the menu | No local Claude activity recently. Not a warning. |

None of this says how much quota is left. If you need that, the terminal tells
you when you are close; VibeCheck tells you when the clock resets.

## Checking it yourself

```console
$ ./build/VibeCheck --check-usage
start:    2026-09-08 12:00
end:      2026-09-08 17:00
elapsed:  0.594
tokens:   16007002
exhausted:false
```
