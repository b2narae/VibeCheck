# Documentation

| | |
|---|---|
| [architecture.md](architecture.md) | How detection works, what each component owns, and every tuning constant. Read this before changing how state is decided. |
| [cli.md](cli.md) | Every command-line flag, the environment variables, and the full list of files VibeCheck reads and writes. |
| [usage-window.md](usage-window.md) | What the runner's height means, why it is a clock and not a fuel gauge, and how the tombstone is triggered. |
| [troubleshooting.md](troubleshooting.md) | A runner ran off mid-turn, a wall is stuck, nothing appears on the external display. |

Elsewhere in the repo:

- [README.md](../README.md) · [README.ko.md](../README.ko.md) — what it is and how to install it
- [CONTRIBUTING.md](../CONTRIBUTING.md) — building, adding an animal, adding an assistant
- [SECURITY.md](../SECURITY.md) — what it reads, what it writes, and what shows on screen
- [CHANGELOG.md](../CHANGELOG.md) — what changed and when

`runners.png` is the sprite contact sheet, produced by
`./build/VibeCheck --dump-sprites`. It is the only capture of this app that
contains no session information.
