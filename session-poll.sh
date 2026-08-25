#!/bin/bash
set -uo pipefail

HOME=${HOME:-/home/apollo}
NOW=$(date +%s)
BLOCKED_THRESHOLD="${1:-30}"

# --- find terminal PID by walking parent chain ---
find_terminal_pid() {
  local pid=$1 ppid comm
  while true; do
    [ "$pid" -le 1 ] && { echo "0"; return; }
    ppid=$(awk '/^PPid:/{print $2}' /proc/$pid/status 2>/dev/null || echo "")
    [ -z "$ppid" ] && { echo "0"; return; }
    comm=$(cat /proc/$ppid/comm 2>/dev/null || echo "")
    case "$comm" in
      foot|kitty|ghostty|alacritty) echo "$ppid"; return ;;
      tmux:*) ;; # skip tmux, keep walking
      *) ;;
    esac
    pid=$ppid
  done
}

# --- get hyprctl window address for a PID ---
get_window_addr() {
  local pid=$1
  hyprctl clients -j 2>/dev/null | python3 -c "
import json,sys
data=json.load(sys.stdin)
for c in data:
    if c.get('pid') == $pid:
        print(c.get('address',''))
        break
" 2>/dev/null || echo ""
}

# --- fallback: get first terminal window address ---
first_terminal_addr() {
  hyprctl clients -j 2>/dev/null | python3 -c "
import json,sys
data=json.load(sys.stdin)
for c in data:
    if c.get('class','') in ('foot','kitty','ghostty','alacritty'):
        print(c.get('address',''))
        break
" 2>/dev/null || echo ""
}

# Cache the first terminal address
FIRST_TERM_ADDR=$(first_terminal_addr)

# --- JSON output ---
printf '{\n'

# --- sessions ---
printf '  "sessions":['
first=true
for pid in $(pgrep -x "claude|opencode" 2>/dev/null || true); do
  cwd=$(readlink /proc/$pid/cwd 2>/dev/null || echo "")
  [ -z "$cwd" ] && continue

  cmd=$(tr '\0' ' ' < /proc/$pid/cmdline 2>/dev/null || echo "")
  cmd="${cmd% }"

  project_dir_name=$(echo "$cwd" | sed 's|/|-|g')
  project_dir="$HOME/.claude/projects/$project_dir_name"
  latest_mtime=0
  if [ -d "$project_dir" ]; then
    latest=$(find "$project_dir" -maxdepth 1 -name '*.jsonl' -printf '%T@ %f\n' 2>/dev/null | sort -rn | head -1 | awk '{printf "%d", $1}')
    [ -n "$latest" ] && latest_mtime="$latest"
  fi

  stale=$(( NOW - latest_mtime ))
  status="working"
  [ "$latest_mtime" -gt 0 ] && [ "$stale" -gt "$BLOCKED_THRESHOLD" ] && status="blocked"

  is_claude=false
  is_opencode=false
  case "$cmd" in
    claude*)  is_claude=true ;;
    opencode*) is_opencode=true ;;
  esac

  term_pid=$(find_terminal_pid "$pid")
  window_addr=""
  if [ "$term_pid" != "0" ]; then
    window_addr=$(get_window_addr "$term_pid" || echo "")
  fi
  # fallback: if no terminal found via parent chain, use first terminal window
  [ -z "$window_addr" ] && window_addr="$FIRST_TERM_ADDR"

  repo_name=$(basename "$cwd")
  agent_type=$([ "$is_claude" = true ] && echo "claude" || echo "opencode")

  # detect tmux pane (always check regardless of term_pid)
  tmux_pane=""
  raw_pane=$(tr '\0' '\n' < /proc/$pid/environ 2>/dev/null | grep '^TMUX_PANE=' | cut -d= -f2 || echo "")
  if [ -n "$raw_pane" ]; then
    # Resolve %N pane id to window.pane format for cross-window targeting
    tmux_pane=$(tmux list-panes -a -F '#{pane_id} #{window_index}.#{pane_index}' 2>/dev/null | awk -v id="$raw_pane" '$1==id {print $2}')
    [ -z "$tmux_pane" ] && tmux_pane="$raw_pane"
  fi

  $first || printf ','
  printf '\n    {"pid":%s,"repo":"%s","cwd":"%s","agent":"%s","status":"%s","stale":%s,"window_addr":"%s","tmux_pane":"%s","cmd":"%s"}' \
    "$pid" "$repo_name" "$cwd" "$agent_type" "$status" "$stale" "$window_addr" "$tmux_pane" "$cmd"
  first=false
done
printf '\n  ]'

# --- worktrees ---
printf ',\n  "worktrees":['
first=true
for d in "$HOME"/Work/repos/*/; do
  [ -d "$d" ] || continue
  repo=$(basename "$d")
  branch=$(git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  dirty=$(git -C "$d" status --porcelain 2>/dev/null | wc -l)

  session_attached=false
  for spid in $(pgrep -x "claude|opencode" 2>/dev/null || true); do
    pid_cwd=$(readlink /proc/$spid/cwd 2>/dev/null || echo "")
    if [ "$pid_cwd" = "${d%/}" ]; then
      session_attached=true
      break
    fi
  done

  $first || printf ','
  printf '\n    {"repo":"%s","path":"%s","branch":"%s","dirty":%s,"session_attached":%s}' \
    "$repo" "${d%/}" "$branch" "$dirty" "$session_attached"
  first=false
done
printf '\n  ]\n'

printf '}\n'
