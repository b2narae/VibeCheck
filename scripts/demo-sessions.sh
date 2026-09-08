#!/bin/bash
# Stages fake assistant sessions so the overlay can be photographed — or worked
# on — without touching a real project, spending any quota, or putting a single
# real prompt on screen.
#
# Nothing here reads or writes your actual ~/.claude or ~/.codex: VibeCheck is
# launched against throwaway config directories, so the runners you see are
# driven entirely by files this script wrote.
#
#   ./scripts/demo-sessions.sh up      stage the sessions and launch VibeCheck
#   ./scripts/demo-sessions.sh shot    capture the screen to demo/
#   ./scripts/demo-sessions.sh down    stop everything and clean up
set -euo pipefail
cd "$(dirname "$0")/.."

# TMPDIR usually ends in a slash; the encoded project path a transcript lives
# under has to match the cwd the kernel reports, so normalise it away.
ROOT="$(cd "${TMPDIR:-/tmp}" && pwd -P)/vibecheck-demo"
APP="build/VibeCheck.app/Contents/MacOS/VibeCheck"
OUT="demo"

# Project names that appear on screen. Deliberately generic.
CLAUDE_A="checkout-service"
CLAUDE_B="pixel-garden"
CODEX_A="notes-api"

stamp() { date -u -v"${1}" +%Y-%m-%dT%H:%M:%S.000Z; }
encode() { printf '%s' "$1" | sed 's/[^a-zA-Z0-9]/-/g'; }

up() {
  down >/dev/null 2>&1 || true
  mkdir -p "$ROOT/bin" "$ROOT/claude/projects" "$ROOT/codex/sessions"

  # A session only needs to *be* a process named like the CLI, using no CPU, so
  # that the transcript is what decides its state — exactly the path we want to
  # exercise. It has to be compiled rather than copied from /bin/sleep: copying
  # a signed system binary invalidates its signature and the kernel kills it.
  cat > "$ROOT/bin/idle.c" <<'C'
#include <unistd.h>
int main(void) { pause(); return 0; }
C
  for name in claude codex gemini; do
    cc -O0 -o "$ROOT/bin/$name" "$ROOT/bin/idle.c"
  done

  for project in "$CLAUDE_A" "$CLAUDE_B" "$CODEX_A"; do
    mkdir -p "$ROOT/work/$project"
  done

  # --- Two Claude sessions, mid-turn -------------------------------------
  # Last entry is a user/tool_result, so the transcript reads as "the model is
  # computing" and the runner keeps running even at 0% CPU.
  for project in "$CLAUDE_A" "$CLAUDE_B"; do
    dir="$ROOT/claude/projects/$(encode "$ROOT/work/$project")"
    mkdir -p "$dir"
    case "$project" in
      "$CLAUDE_A") prompt="add a retry to the payment webhook";
                   answer="Looking at the webhook handler now." ;;
      *)           prompt="make the sprite sheet twice as wide";
                   answer="I'll widen the contact sheet and re-render." ;;
    esac
    {
      printf '{"type":"user","timestamp":"%s","message":{"role":"user","content":"%s"}}\n' \
        "$(stamp -4M)" "$prompt"
      printf '{"type":"assistant","timestamp":"%s","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"text","text":"%s"}],"usage":{"input_tokens":900,"output_tokens":180}}}\n' \
        "$(stamp -3M)" "$answer"
      printf '{"type":"user","timestamp":"%s","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}\n' \
        "$(stamp -1M)"
    } > "$dir/$(uuidgen).jsonl"
  done

  # --- One Codex session, stopped on an approval -------------------------
  # `*_approval_request` as the newest event is read as "blocked on you", so a
  # brick wall drops in front of this one.
  day=$(date -u +%Y/%m/%d)
  mkdir -p "$ROOT/codex/sessions/$day"
  {
    printf '{"timestamp":"%s","type":"session_meta","payload":{"session_id":"%s","cwd":"%s","originator":"codex-tui","cli_version":"demo"}}\n' \
      "$(stamp -6M)" "$(uuidgen)" "$ROOT/work/$CODEX_A"
    printf '{"timestamp":"%s","type":"event_msg","payload":{"type":"user_message","message":"run the test suite once before we tag"}}\n' \
      "$(stamp -5M)"
    printf '{"timestamp":"%s","type":"event_msg","payload":{"type":"task_started","turn_id":"demo"}}\n' \
      "$(stamp -5M)"
    printf '{"timestamp":"%s","type":"event_msg","payload":{"type":"agent_message","message":"Running the suite now."}}\n' \
      "$(stamp -4M)"
    printf '{"timestamp":"%s","type":"event_msg","payload":{"type":"exec_approval_request","command":"npm test -- --runInBand"}}\n' \
      "$(stamp -2M)"
  } > "$ROOT/codex/sessions/$day/rollout-$(date -u +%Y-%m-%dT%H-%M-%S)-$(uuidgen).jsonl"

  # --- Launch the fake sessions ------------------------------------------
  # Fully detached, or whoever ran this script waits on their pipes forever.
  ( cd "$ROOT/work/$CLAUDE_A" && nohup "$ROOT/bin/claude" >/dev/null 2>&1 & )
  ( cd "$ROOT/work/$CLAUDE_B" && nohup "$ROOT/bin/claude" >/dev/null 2>&1 & )
  ( cd "$ROOT/work/$CODEX_A"  && nohup "$ROOT/bin/codex"  >/dev/null 2>&1 & )

  # --- Launch VibeCheck against the throwaway config ----------------------
  pkill -f "VibeCheck.app/Contents/MacOS/VibeCheck" 2>/dev/null || true
  sleep 1
  CLAUDE_CONFIG_DIR="$ROOT/claude" CODEX_HOME="$ROOT/codex" \
    nohup "$APP" >/dev/null 2>&1 &

  echo "staged in $ROOT"
  echo "  running: $CLAUDE_A, $CLAUDE_B   blocked at a wall: $CODEX_A"
  echo "give it ~6s, then check the menu bar. './scripts/demo-sessions.sh shot' captures."
}

verify() {
  CLAUDE_CONFIG_DIR="$ROOT/claude" CODEX_HOME="$ROOT/codex" \
    ./build/VibeCheck --debug 2>&1 &
  local pid=$!
  sleep 7
  kill $pid 2>/dev/null || true
}

shot() {
  mkdir -p "$OUT"
  local base="$OUT/vibecheck-$(date +%H%M%S)"
  screencapture -x -t png "$base.png"

  # A 1200x750 derivative: capture is Retina, so crop 2x that and halve it.
  local w h
  w=$(sips -g pixelWidth "$base.png" | awk '/pixelWidth/{print $2}')
  h=$(sips -g pixelHeight "$base.png" | awk '/pixelHeight/{print $2}')
  if [ "$w" -ge 2400 ] && [ "$h" -ge 1500 ]; then
    sips -c 1500 2400 "$base.png" --out "$base-1200x750.png" >/dev/null
    sips -z 750 1200 "$base-1200x750.png" >/dev/null
    echo "wrote $base.png and $base-1200x750.png"
  else
    sips -z 750 1200 "$base.png" --out "$base-1200x750.png" >/dev/null
    echo "wrote $base.png and $base-1200x750.png (screen smaller than 2400x1500; scaled, not cropped)"
  fi

  cat <<'WARN'

Before this goes anywhere public, look at it:
  * every window behind the runners is in the frame
  * open the menu only if you want its contents published — the dropdown lists
    project names, including sessions this script did not create
  * the click panel shows a prompt and a reply verbatim
WARN
}

down() {
  pkill -f "$ROOT/bin/" 2>/dev/null || true
  pkill -f "VibeCheck.app/Contents/MacOS/VibeCheck" 2>/dev/null || true
  rm -rf "$ROOT"
  echo "demo torn down (your real VibeCheck is not running; relaunch it if you want it)"
}

case "${1:-up}" in
  up) up ;;
  verify) verify ;;
  shot) shot ;;
  down) down ;;
  *) echo "usage: $0 {up|verify|shot|down}" >&2; exit 1 ;;
esac
