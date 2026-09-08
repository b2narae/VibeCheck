# Architecture

How VibeCheck decides what your assistants are doing, and why it is built this
way. The README's "How it actually works" is the short version; this is the one
you want before changing detection.

## The one guarantee

**A runner is on screen if and only if that session is working, and it stops
when the session stops.** Everything below exists to keep that true. A runner
that lies is worse than no runner: the product's whole value is that you can
trust a glance instead of checking.

Two failure modes matter, and they are not symmetric:

- **Saying "finished" too early** is the serious one. You go look, the session
  is mid-turn, and you stop trusting the animal.
- **Saying "still working" too long** is mild. You glance again a moment later.

So every ambiguous signal resolves toward "still working", bounded by a timeout.

## The pieces

```
main.swift ─────────── CLI flags, then either --debug or the AppKit app
  └── AppDelegate ──── owns everything, wires the callbacks
        ├── ProcessMonitor ──── polls, decides each session's state
        │     ├── ProcessList ──────── libproc/sysctl process table + CPU
        │     ├── HookBridge ───────── Claude Code hook reports
        │     └── Transcripts ──────── TranscriptReader per assistant
        │           ├── ClaudeTranscript
        │           └── CodexTranscript
        ├── UsageWindowTracker ─ the Claude 5-hour block
        ├── OverlayController ── the runners, walls and click panel
        └── StatusBarController  menu bar readout, settings, sounds
              └── SessionSummary  the lines both the menu and panel show
```

`ProcessMonitor` is the only component that decides state. The overlay and menu
render what it reports and never form an opinion of their own — that is what
keeps the menu bar and the animals from disagreeing.

## Threading

- `ProcessMonitor` and `UsageWindowTracker` each own a serial `DispatchQueue`.
  Every mutable field they hold is confined to that queue.
- Both are `@unchecked Sendable`: the compiler cannot see the queue confinement,
  and the callbacks are snapshotted in `start()` so they cannot be swapped
  mid-poll.
- Callbacks are declared `@MainActor` and delivered with
  `DispatchQueue.main.async { MainActor.assumeIsolated { … } }`.
- Everything AppKit-facing — `OverlayController`, `StatusBarController`,
  `SessionAnimals`, `SessionSummary`, `Sprites` — is `@MainActor`.

The package builds in Swift 6 language mode with no warnings, so these are
checked rather than hoped for.

## The polling loop

Every **1.5 s**, `ProcessMonitor.poll()`:

1. **Reads the process table** through `ProcessList.snapshot(argvFor:)`.
   `proc_listallpids` plus `proc_pidinfo(PROC_PIDTBSDINFO)` gives pid, ppid and
   the executable name. Full argv (`KERN_PROCARGS2`) is fetched **only** for
   processes whose name could belong to an assistant or an interpreter that
   launches one (`node`, `bun`, `deno`, `npx`, `npm`) — 9 of 783 processes on
   the machine this was measured on, in 0.8 ms total.
   `ProcessList.snapshotViaPS()` remains as a fallback if the kernel gives us
   nothing.

2. **Matches sessions.** `ProcessMonitor.match(args:)` takes the basename of the
   first two argv tokens, which covers both `claude …` and `node /path/cli.js …`.
   It rejects:
   - resident helpers — anything containing ` daemon run`, `bg-pty-host`,
     `bg-spare` or `.app/`;
   - one-shot invocations, by the token after the binary: `auth`, `config`,
     `mcp`, `exec`, `-p`, `--print`, `--version`, and the rest of
     `nonSessionArguments`.

3. **Drops nested matches.** `rootSessions(_:parentOf:)` removes any match that
   descends from another. That is how an MCP server or a dev script shelling out
   to a CLI stops becoming a phantom session — and how the npm shim
   (`node …/codex.js`) and the native binary it spawns collapse into one.

4. **Measures CPU.** The whole process subtree is walked, stopping at nested
   sessions so they are not double-counted, and each pid's consumed CPU time
   (`proc_pid_rusage`) is differenced against the previous poll. A session is
   `cpuActive` if any of the last **4 samples** (~6 s) reached **8%**.

   > `ps`'s `pcpu` is a decaying average over a process's whole lifetime, which
   > answers "has this been busy" rather than "is this busy". Differencing
   > consumed time answers the question actually being asked.

5. **Resolves the transcript** and classifies its tail (mtime-cached, so an
   unchanged log is free). A lookup that fails backs off **15 s**.

6. **Decides**, in strict priority order — see below.

7. **Emits** `onUpdate`, plus `onFinished`, `onNeedsAttention` and
   `onSessionActive` edges, on the main actor.

## How state is decided

```
first sighting (fewer than 2 CPU samples)  → idle
    ↓ otherwise
a trusted hook report for this assistant   → whatever it says
    ↓ otherwise
the transcript tail                        → see the table
    ↓ otherwise
CPU alone                                  → working above the threshold
```

**A new pid is held idle for one poll.** A one-shot call that slips past the
argv filters dies before it can flash a runner on screen.

### Hook reports, and when they are distrusted

Hooks are ground truth — Claude Code states its own phase instead of us
inferring it — but some transitions fire no event at all, so a report is only
trusted while the transcript agrees (`ProcessMonitor.trusts`):

| Report | Trusted while | Why |
|---|---|---|
| `working` | the log was written within **180 s** | Interrupting a turn with Esc fires no `Stop` hook, so a stale "working" would pin the runner forever. |
| `attention` | the log has not moved past the report (2 s slack) | Approving a permission prompt fires no hook either, so the wall must come down when the transcript continues. |
| `idle` | always | Nothing contradicts "finished". |

Reports carry the assistant that made them, and are matched by pid, then session
id, then working directory — the last only when exactly one session of that
assistant reports from it.

### Transcript tail states

`LogTailState` is what the tail says, independent of assistant:

| State | Meaning | Effect |
|---|---|---|
| `awaitingAssistant` | the model is computing | **working**, if the log is newer than 180 s |
| `pendingToolUse` | a tool call has no result yet | **working**; but if CPU is quiet and it has sat **10 s**, it is a prompt waiting on you → wall |
| `awaitingUser` | the assistant said outright it needs you | **wall**, immediately |
| `turnEnded` | the turn is over | **idle** |
| `unknown` | nothing conclusive | fall through to CPU |

## The transcript readers

`TranscriptReader` is four static functions: locate the log, classify the tail,
read the last instruction, read the detail. `Transcripts.reader(for:)` maps an
assistant id to one.

Both readers use `Transcripts.forEachLineFromEnd(of:limit:)`, which reads the
tail once and walks lines backwards, **decoding only the lines it examines**.
Transcripts answer every question from their newest few entries, so splitting a
multi-megabyte tail into strings up front is work thrown away.

> This was measured. Splitting the whole window cost 173 ms to open the menu
> across five sessions. Reading progressively larger windows — the obvious way
> to reach an instruction buried under tool output — made it **worse** (334 ms),
> because each widening re-parsed everything it had already seen. Walking
> backwards costs 47 ms and lets the window be 4 MB, which is what makes a
> buried instruction reachable at all.

### Claude Code

Logs live in `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`, where the
encoding replaces every non-alphanumeric character with `-`. `CLAUDE_CONFIG_DIR`
is honoured. Without a session id, the project's most recently written log wins.

Turn completion is decided by **`stop_reason`**, never by content:

```
end_turn | stop_sequence | max_tokens | refusal   → turnEnded
tool_use                                          → more is coming
```

> Text and thinking blocks are written *mid-turn*. Judging by "did the assistant
> say something" marks a busy session finished dozens of times per turn, and the
> runners dash off and re-enter continuously. This was a real bug, fixed in
> 0.1.0, and it is the single easiest thing to reintroduce.

Candidate lines are JSON-parsed, never string-matched, so a transcript that
merely *quotes* `"stop_reason":"end_turn"` cannot fake a finished turn.

### Codex CLI

Rollouts live in `$CODEX_HOME/sessions/YYYY/MM/DD/rollout-<timestamp>-<id>.jsonl`
(default `~/.codex`). Codex puts no session id on its command line, so a running
process is matched to its rollout by the `cwd` recorded in the `session_meta`
first line — read from the first **64 KB**, since that line also carries the
entire base prompt.

Candidates are the newest **14 day folders**, filtered to files written within
**3 days**, newest first, capped at **12**.

> The folder is named for the day a session *started*, and a long session keeps
> appending to the same file. Over 106 real sessions, 1 in 10 was still being
> written a day or more later and one ran four days — so selecting by folder
> date lost exactly the long-running sessions this reader exists for. Selection
> is by file mtime: a live session is being written to, whatever its folder says.

The tail scan stops at the first decisive event:

| Event | State |
|---|---|
| `task_complete`, `turn_aborted` | `turnEnded` |
| `task_started`, `user_message` | `awaitingAssistant` |
| `*_approval_request` | `awaitingUser` |
| `function_call`, `custom_tool_call` without a terminal `status` | `pendingToolUse` |
| any output, message, reasoning or patch event | `awaitingAssistant` |
| `token_count`, settings, world-state entries | **skipped** |

Skipping `token_count` matters: it fires constantly mid-turn, and treating one
as decisive would make every Codex session look finished. Because the scan runs
backwards and stops at the first hit, an approval that has since been answered
is buried under the tool output that followed it — which is what lowers the
wall, since approving fires no second event.

### Gemini CLI

No reader. Gemini CLI writes no session transcript we can read, so its sessions
are judged by CPU alone and a session that is only *waiting* can look finished.
This is stated in the README's per-assistant table rather than papered over. If
you know where Gemini CLI records its turns, that is a small and very welcome PR
— implement `TranscriptReader` and register it in `Transcripts.reader(for:)`.

## The Claude 5-hour block

`UsageWindowTracker` estimates the block the way
[ccusage](https://github.com/ryoppippi/ccusage) does: the first activity after
the previous block ended, floored to the hour, plus five hours. It recomputes
every **60 s**, and immediately whenever a session starts a turn — a block can
begin the moment you type, and a runner drawn against a minute-old block is
visibly wrong right after a break.

**It measures time, not consumption.** See
[docs/usage-window.md](usage-window.md) for why, and for what the tombstone
actually means.

Scanning is incremental: logs are append-only, so each file is read once and
afterwards only from where the last pass stopped, in 4 MB chunks, parsed as raw
UTF-8 bytes rather than decoded into `String`. Reading a day of history in full
every minute cost 18.5 s; this costs 1.1 s cold and effectively nothing warm.

## The overlay

- One borderless, transparent window covering the **union of every screen**,
  rebuilt when displays change.
- `ignoresMouseEvents` is toggled per frame: the overlay is click-through
  except when the cursor is actually over a runner or its wall.
- 30 fps tick; a gait frame every 8 ticks; runners cross in about a minute.
- Claude runners' **altitude** is `1 - elapsedFraction` of the block, staggered
  14 pt per lane; other assistants use fixed lanes 55 pt apart. Lanes scale
  with screen height, 4 to 8.
- Alpha fades to **0.28** as the block runs down — never far enough to lose.
- With **Reduce Motion** on, runners hold still; walls, altitude, fade and the
  click panel all still work.

## Tuning constants

Everything that could need adjusting, in one place.

| Constant | Value | File |
|---|---|---|
| `pollInterval` | 1.5 s | `ProcessMonitor` |
| `workingCPUThreshold` | 8% | `ProcessMonitor` |
| `historySize` | 4 samples (~6 s) | `ProcessMonitor` |
| `turnActivityHorizon` | 180 s | `ProcessMonitor` |
| `pendingAttentionGrace` | 10 s | `ProcessMonitor` |
| `logFileRetryInterval` | 15 s | `ProcessMonitor` |
| `tailChunk` | 256 KB | both readers |
| `deepChunk` | 4 MB | `Transcripts` |
| `headChunk` | 64 KB | `CodexTranscript` |
| `dayFoldersScanned` / `liveWindow` / `maxCandidates` | 14 / 3 days / 12 | `CodexTranscript` |
| `blockLength` / `recomputeInterval` / `lookback` | 5 h / 60 s / 24 h | `UsageWindowTracker` |
| `tickInterval` / `ticksPerGaitFrame` | 1/30 s / 8 | `OverlayController` |
| `minRunnerAlpha` | 0.28 | `OverlayController` |

If you raise `workingCPUThreshold`, remember it is now instantaneous
utilisation, not `ps`'s lifetime average — the numbers are not comparable to
anything from before 0.2.0.
