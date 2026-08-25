#!/bin/bash
# Bring the terminal that hosts our tmux client to the foreground, optionally
# selecting a pane or opening a new window in it first.
#
# Usage:
#   focus-session.sh tmux-new <path>          new tmux window rooted at <path>
#   focus-session.sh <window>.<pane> [addr]   select an existing tmux pane
#   focus-session.sh "" <addr>                focus a plain (non-tmux) window
#
# Focus is dispatched LAST and then verified. The bar panel calls this right
# after it closes, and Hyprland re-computes keyboard focus when the panel's
# layer surface unmaps -- which can land *after* our dispatch and take focus
# straight back. Retrying until hyprctl agrees is what makes this reliable;
# a fixed delay only moves the race around.

set -uo pipefail

# The tmux client we are steering: its tty identifies the terminal window, and
# its session name targets tmux commands at the session the user is looking at
# rather than whichever one tmux happened to touch last.
client_tty=""
client_session=""
client_line=$(tmux list-clients -F '#{client_tty} #{client_session}' 2>/dev/null | head -1)
if [ -n "$client_line" ]; then
  client_tty=${client_line%% *}
  client_session=${client_line#* }
fi

active_address() {
  hyprctl activewindow -j 2>/dev/null |
    python3 -c 'import json,sys; print(json.load(sys.stdin).get("address") or "")' 2>/dev/null
}

# Reads `hyprctl clients -j` on stdin and a seed pid as argv[1]; prints the
# address of the window that pid belongs to, else the first terminal window.
PICK_TERMINAL=$(cat <<'PYPICK'
import json, sys

TERMINALS = ("foot", "kitty", "ghostty", "alacritty")
clients = json.load(sys.stdin)
by_pid = {}
for client in clients:
    by_pid.setdefault(client.get("pid"), client.get("address") or "")


def ancestors(pid):
    while pid and pid > 1:
        yield pid
        try:
            with open("/proc/%d/status" % pid) as handle:
                pid = next(int(line.split()[1]) for line in handle if line.startswith("PPid:"))
        except (OSError, StopIteration, ValueError):
            return


seed = sys.argv[1] if len(sys.argv) > 1 else ""
if seed.isdigit():
    for pid in ancestors(int(seed)):
        if by_pid.get(pid):
            print(by_pid[pid])
            sys.exit(0)

for client in clients:
    if client.get("class") in TERMINALS and client.get("address"):
        print(client["address"])
        sys.exit(0)
PYPICK
)

# Hyprland address of the window hosting $client_tty. Matching by tty beats
# "first foot window wins": with more than one terminal open, the arbitrary
# pick lands on the wrong one.
terminal_address() {
  local tty_pid=""
  if [ -n "$client_tty" ]; then
    tty_pid=$(ps -o pid= -t "${client_tty#/dev/}" 2>/dev/null | head -1 | tr -d ' ')
  fi
  hyprctl clients -j 2>/dev/null | python3 -c "$PICK_TERMINAL" "${tty_pid:-}" 2>/dev/null
}

# Dispatch focus and confirm it stuck, re-dispatching if something else (the
# closing panel) claimed it in between.
focus_window() {
  local addr=$1 attempt
  [ -n "$addr" ] || return 1
  for attempt in 1 2 3 4 5 6; do
    hyprctl dispatch "hl.dsp.focus({ window = \"address:$addr\" })" >/dev/null
    [ "$(active_address)" = "$addr" ] && return 0
    sleep 0.06
  done
  [ "$(active_address)" = "$addr" ]
}

target() { printf '%s' "$client_session"; }

if [ "${1:-}" = "tmux-new" ]; then
  tmux new-window -t "$(target):" -c "${2:-$HOME}"
  focus_window "$(terminal_address)"
elif [ -n "${1:-}" ]; then
  # Existing tmux pane, addressed as <window>.<pane> by session-poll.sh.
  win=${1%%.*}
  pane=${1##*.}
  tmux select-window -t "$(target):$win"
  tmux select-pane -t "$(target):$win.$pane"
  # Prefer the address session-poll.sh recorded; fall back if it went stale.
  focus_window "${2:-}" || focus_window "$(terminal_address)"
elif [ -n "${2:-}" ]; then
  # Standalone (non-tmux) session: nothing to select, just focus the window.
  focus_window "$2"
fi
