#!/bin/bash
# Bring the terminal that hosts our tmux client to the foreground, optionally
# selecting a pane or opening a new window in it first.
#
# Usage:
#   focus-session.sh open-term <path> [term]  open <path> in a new terminal
#   focus-session.sh tmux-new <path> [term]   new tmux window rooted at <path>
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
#
# The address is checked against the shape Hyprland actually uses before it is
# interpolated. It reaches us as an argument rather than through the shell, so
# this is not about quoting -- it is that hyprctl parses the dispatch string as
# an expression, and an argument that arrives malformed should be refused here
# rather than handed to a parser to make sense of.
focus_window() {
  local addr=$1 attempt
  [ -n "$addr" ] || return 1
  case "$addr" in
    0x*) case "${addr#0x}" in '' | *[!0-9a-fA-F]*) return 1 ;; esac ;;
    *) return 1 ;;
  esac
  for attempt in 1 2 3 4 5 6; do
    hyprctl dispatch "hl.dsp.focus({ window = \"address:$addr\" })" >/dev/null
    [ "$(active_address)" = "$addr" ] && return 0
    sleep 0.06
  done
  [ "$(active_address)" = "$addr" ]
}

target() { printf '%s' "$client_session"; }

# launch_terminal <workdir> <preferred> [command...]
#
# Replaces this process with a terminal at <workdir>, optionally running a
# command in it. Every terminal spells the working-directory flag differently
# and they disagree about whether a command is positional or needs -e, so the
# choice and its spelling have to travel together. xdg-terminal-exec comes
# before any named terminal: it launches whatever the user set as their
# desktop default. Returns non-zero only if nothing on the list is installed.
launch_terminal() {
  local workdir=$1 preferred=$2 candidate
  shift 2
  for candidate in "$preferred" "${TERMINAL:-}" xdg-terminal-exec alacritty foot kitty ghostty; do
    [ -n "$candidate" ] || continue
    command -v "$candidate" >/dev/null 2>&1 || continue
    local -a argv
    case "$(basename "$candidate")" in
      xdg-terminal-exec) argv=("$candidate" --dir="$workdir")
                         [ "$#" -gt 0 ] && argv+=(--) ;;
      kitty)             argv=("$candidate" --directory "$workdir") ;;
      ghostty)           argv=("$candidate" --working-directory="$workdir")
                         [ "$#" -gt 0 ] && argv+=(-e) ;;
      alacritty)         argv=("$candidate" --working-directory "$workdir")
                         [ "$#" -gt 0 ] && argv+=(-e) ;;
      # foot, and anything the user named that behaves like it: the command is
      # positional, so it needs no separator at all.
      *)                 argv=("$candidate" --working-directory "$workdir") ;;
    esac
    exec "${argv[@]}" "$@"
  done
  return 1
}

if [ "${1:-}" = "open-term" ]; then
  launch_terminal "${2:-$HOME}" "${3:-}"
  exit 1
elif [ "${1:-}" = "tmux-new" ]; then
  workdir="${2:-$HOME}"
  # `tmux new-window` needs a server that is already running -- unlike
  # new-session it will not start one -- so with no tmux around it failed, left
  # nothing to focus, and pressing `t` did nothing at all. The absence of an
  # attached client is the case to detect: without one there is no session to
  # put a window in and no terminal showing it.
  #
  # So when tmux is not running, start it. Opening a terminal on a new session
  # rooted at the worktree is what "open this in tmux" means when there is no
  # tmux yet, and it is the same terminal-launching path `enter` already uses.
  if [ -n "$client_session" ] && tmux new-window -t "$(target):" -c "$workdir"; then
    focus_window "$(terminal_address)"
  else
    launch_terminal "$workdir" "${3:-}" tmux new-session -c "$workdir"
  fi
elif [ -n "${1:-}" ]; then
  # An existing pane, in one of the two shapes session-poll.sh emits: the
  # <window>.<pane> pair it resolves, or the raw %N pane id it falls back to
  # when that lookup comes up empty. Both are matched by deleting the digits
  # and looking at what is left, which is exact where a glob is not --
  # "1x.2" satisfies [0-9]*.[0-9]* and is not a pane reference.
  #
  # Anything else is not something this plugin produced. There is nothing to
  # select, so the window is focused and tmux keeps whatever pane it is on,
  # rather than a stray value being passed to tmux to interpret as a target.
  case "${1//[0-9]/}" in
    ".") win=${1%%.*}
         pane=${1##*.}
         tmux select-window -t "$(target):$win"
         tmux select-pane -t "$(target):$win.$pane" ;;
    "%") tmux select-pane -t "$1" ;;
  esac
  # Prefer the address session-poll.sh recorded; fall back if it went stale.
  focus_window "${2:-}" || focus_window "$(terminal_address)"
elif [ -n "${2:-}" ]; then
  # Standalone (non-tmux) session: nothing to select, just focus the window.
  focus_window "$2"
fi
