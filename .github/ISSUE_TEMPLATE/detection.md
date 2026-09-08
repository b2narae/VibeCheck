---
name: A runner is wrong
about: A runner ran off mid-turn, never appeared, or a wall is stuck
title: ''
labels: detection
---

<!-- Detection is the part that goes wrong, and "it looked wrong" is hard to
     act on. The two commands below usually contain the answer. -->

**What the runner did, and what the session was actually doing**

**Assistant** Claude Code / Codex CLI / Gemini CLI, and its version
(`claude --version`)

**Hooks on?** output of `VibeCheck --hooks-status`

**`VibeCheck --debug`**, covering the moment it went wrong

```
paste here — this prints file names, not conversations, so it is safe to share
```

**`VibeCheck --check-session <the session's directory>`**

```
paste here — REDACT the prompt and answer lines, they contain your conversation
```

**macOS version**

<!-- Please don't paste transcript contents. See SECURITY.md. -->
