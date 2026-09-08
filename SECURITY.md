# Security and privacy

VibeCheck reads your coding sessions' local logs and can edit one Claude Code
settings file. That is worth being precise about, so here is everything it
touches and everything it does not do.

## It has no network code

There is no networking in this app. Not telemetry, not update checks, not crash
reporting, not an analytics SDK. Nothing your sessions contain leaves your
machine, because there is no code that could send it.

You can confirm this rather than take it on faith:

```console
$ grep -rE "URLSession|NSURLConnection|Network\.|CFSocket|socket\(|getaddrinfo" Sources/
```

The whole import list is `AppKit`, `Foundation`, `ServiceManagement` and
`Darwin` — the last for `proc_pidinfo` and `sysctl`, which is how sessions are
found without spawning `ps`. Everything else the binary links is the Swift
runtime and what AppKit pulls in; `otool -L build/VibeCheck` shows it. There is
no network entitlement.

## What it reads

| Path | Why |
|---|---|
| `~/.claude/projects/**/*.jsonl` | turn state, the last instruction, the last answer, the pending tool call, and message timestamps for the 5-hour block |
| `~/.codex/sessions/**/*.jsonl` | the same, from Codex rollouts |
| the process table (libproc/sysctl) | to find sessions and measure CPU |
| each session's working directory (`proc_pidinfo`) | the project name, and to match a session to its log |

Only the **tail** of a transcript is read — 256 KB to classify the turn, up to
4 MB to find the instruction and the last answer.

## What it writes

| Path | What |
|---|---|
| `~/.vibecheck/sessions/<session-id>.json` | the phase a hook reported: session id, pid, working directory, phase, and the notification text. Deleted on `SessionEnd`, and pruned after 7 days. |
| `~/.claude/settings.json` | **only** when you turn hooks on or off |
| `~/.claude/settings.json.vibecheck-backup` | a one-time copy, written before the first edit |
| `UserDefaults` | your overlay, animal and sound preferences |

The settings edit is a **merge**: the file is parsed as JSON, VibeCheck's five
hook entries are added or removed, and everything else is written back
untouched. Uninstalling removes only entries whose command contains `--hook` and
the app's own name — including the former name *Gallop*, so an upgrade cannot
leave you running a binary that no longer exists.

## What is on screen

This is the part worth thinking about before you share a screen.

**The click panel and the menu render your prompts and the assistant's replies.**
That is the feature. It also means a screen recording, a screenshot, or a shared
window can expose:

- project directory names,
- what you asked the assistant,
- what it answered,
- the exact command it wants permission to run.

The only capture guaranteed to contain no session information is the sprite
contact sheet:

```console
$ ./build/VibeCheck --dump-sprites runners.png
```

When filing a bug, `--debug` output is safe to share (file names, not contents);
`--check-session` output is **not** — redact it.

## Hook cost

Hooks block the session that invokes them, so VibeCheck registers only the five
turn-boundary events and never per-tool ones, which fire dozens of times per
turn. The hook reads stdin, writes one small JSON file and exits — about 10 ms.
It never fails loudly: a monitoring hook must not disturb the session that
called it.

## Permissions

VibeCheck needs no Accessibility, Screen Recording, Full Disk Access or
Automation permission. It reads files in your own home directory and the process
table for your own user.

It is distributed as source and built locally. `scripts/make-app.sh` applies an
**ad-hoc signature** so that "Open at login" works; there is no Developer ID
signature or notarisation, and no signed binaries are distributed.

## Reporting a vulnerability

Open an issue at
[github.com/b2narae/VibeCheck/issues](https://github.com/b2narae/VibeCheck/issues).
If the issue would expose someone's data by being described publicly, say so
briefly in the issue without the details, and a private channel will be
arranged.

Please include the version (`CFBundleShortVersionString` in the app's
`Info.plist`, or the commit you built) and macOS version. **Do not include
transcript contents.**

## Supported versions

The `main` branch is what is supported. There are no maintained release
branches; fixes land on `main` and you rebuild.
