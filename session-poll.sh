#!/bin/bash
# Emits the JSON the bar widget renders: running agent sessions and the state
# of every git worktree.
#
# Every string that reaches the output goes through jq, never printf. Command
# lines come from /proc/<pid>/cmdline and routinely contain newlines, quotes
# and backslashes -- an agent invoked with a multi-line prompt is enough --
# and hand-built JSON turns that into a parse error, which the widget swallows
# and then silently renders stale data.
set -uo pipefail

HOME="${HOME:-$(getent passwd "$(id -un)" | cut -d: -f6)}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
NOW=$(date +%s)
# Blocked is now a semantic state (an unanswered question), so it needs no
# threshold. The only thing time still decides is when a session that claims to
# be mid-loop has actually died.
STUCK_AFTER="${1:-600}"

# Colon-separated list of directories whose immediate children are scanned as
# worktrees. Configurable because "~/Work/repos" is one person's layout, not a
# convention. A leading ~ is expanded here; the shell never sees these quoted
# values otherwise.
WORKTREE_ROOTS="${2:-$HOME/Work/repos}"


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

# --- opencode session state -------------------------------------------------
# opencode keeps its history in a SQLite db keyed by working directory, which
# beats file mtimes: each assistant message records how its turn ended, and a
# pending question is recorded as a tool part still in the running state.
#
#   a running 'question' tool part -> stopped on an answer from the user
#   finish = 'tool-calls'          -> mid agent loop, working
#   finish = 'stop'                -> turn ended; finished or waiting, unknowable
#   finish = 'unknown'|'length'|NULL -> turn ended too (NULL is an aborted turn,
#                                     MessageAbortedError)
#   time.completed IS NULL         -> nominally in flight, but a killed session
#                                     leaves this behind forever, so it is never
#                                     trusted alone -- staleness catches it.
#
# The question lookup is scoped to the newest message per directory on purpose:
# an abandoned session can leave a 'running' question outstanding for days, and
# this db has two such orphans.
#
# One query covers every directory; ~20ms against a 500MB db.
OPENCODE_DB="${XDG_DATA_HOME:-$HOME/.local/share}/opencode/opencode.db"
declare -A OC_STATE OC_TS

if command -v sqlite3 >/dev/null 2>&1 && [ -f "$OPENCODE_DB" ]; then
  while IFS=$'\x1f' read -r oc_dir oc_role oc_finish oc_completed oc_ts oc_question; do
    [ -n "$oc_dir" ] || continue
    if [ "${oc_question:-0}" -gt 0 ] 2>/dev/null; then
      OC_STATE["$oc_dir"]=blocked
    elif [ "$oc_role" = "assistant" ] && [ -n "$oc_completed" ] && [ "$oc_finish" != "tool-calls" ]; then
      OC_STATE["$oc_dir"]=idle
    else
      OC_STATE["$oc_dir"]=working
    fi
    OC_TS["$oc_dir"]=$(( ${oc_ts:-0} / 1000 ))
  done < <(sqlite3 -readonly -separator $'\x1f' "$OPENCODE_DB" "
    WITH newest AS (
      SELECT s.directory AS dir, m.id AS mid, m.data AS mdata,
             ROW_NUMBER() OVER (PARTITION BY s.directory
                                ORDER BY m.time_created DESC) AS rn
      FROM message m JOIN session s ON s.id = m.session_id
    )
    SELECT n.dir,
           IFNULL(json_extract(n.mdata, '\$.role'), ''),
           IFNULL(json_extract(n.mdata, '\$.finish'), ''),
           IFNULL(json_extract(n.mdata, '\$.time.completed'), ''),
           COALESCE(json_extract(n.mdata, '\$.time.completed'),
                    json_extract(n.mdata, '\$.time.created')),
           (SELECT COUNT(*) FROM part p
              WHERE p.message_id = n.mid
                AND json_extract(p.data, '\$.type') = 'tool'
                AND json_extract(p.data, '\$.tool') = 'question'
                AND json_extract(p.data, '\$.state.status') = 'running')
    FROM newest n WHERE n.rn = 1;" 2>/dev/null)
fi


# --- sessions ---
sessions=()
for pid in $(pgrep -x "claude|opencode" 2>/dev/null || true); do
  cwd=$(readlink /proc/$pid/cwd 2>/dev/null || echo "")
  [ -z "$cwd" ] && continue

  cmd=$(tr '\0' ' ' < /proc/$pid/cmdline 2>/dev/null || echo "")
  cmd="${cmd% }"

  # Claude Code names its transcript dir after the cwd with both '/' and '.'
  # replaced by '-'. Translating only '/' misses every path containing a dot,
  # which leaves latest_mtime at 0 and pins the session to "working".
  # Identify the agent from /proc/<pid>/comm, not the command line. pgrep -x
  # already matched on comm, so it is exactly "claude" or "opencode"; globbing
  # the command line instead mislabelled every absolute-path launch (a mise
  # shim resolves to /home/.../installs/claude/latest/claude, which matched
  # neither pattern and silently fell through to "opencode").
  agent_type=$(cat /proc/$pid/comm 2>/dev/null || echo "")
  is_claude=false
  is_opencode=false
  case "$agent_type" in
    claude)   is_claude=true ;;
    opencode) is_opencode=true ;;
    *)        continue ;;
  esac

  # Each agent is read on its own terms. Both expose the same four states:
  #   blocked  stopped on an unanswered question -- the only urgent state
  #   working  mid agent loop
  #   idle     turn ended; finished or waiting, not distinguishable
  #   stuck    claims mid-loop but has not moved in STUCK_AFTER seconds
  status="working"
  state_at=0

  if [ "$is_opencode" = true ] && [ -n "${OC_TS[$cwd]:-}" ]; then
    status="${OC_STATE[$cwd]}"
    state_at="${OC_TS[$cwd]}"
  elif [ "$is_claude" = true ]; then
    # Claude names its transcript dir after the cwd with both '/' and '.'
    # replaced by '-'; translating only '/' misses every path containing a dot.
    project_dir="$HOME/.claude/projects/$(printf '%s' "$cwd" | sed 's|[/.]|-|g')"
    claude_state=$(python3 "$SCRIPT_DIR/agent-state.py" "$project_dir" 2>/dev/null || echo "unknown|0")
    status="${claude_state%%|*}"
    state_at="${claude_state##*|}"
    [ "$status" = "unknown" ] && status="working"
  fi

  stale=0
  [ "${state_at:-0}" -gt 0 ] 2>/dev/null && stale=$(( NOW - state_at ))

  # A loop that has not moved in a long time is not working, it is gone.
  [ "$status" = "working" ] && [ "$stale" -gt "$STUCK_AFTER" ] && status="stuck"

  term_pid=$(find_terminal_pid "$pid")
  window_addr=""
  if [ "$term_pid" != "0" ]; then
    window_addr=$(get_window_addr "$term_pid" || echo "")
  fi
  # fallback: if no terminal found via parent chain, use first terminal window
  [ -z "$window_addr" ] && window_addr="$FIRST_TERM_ADDR"

  repo_name=$(basename "$cwd")

  # The panel never displays the full command line, and a multi-line agent
  # prompt can run to kilobytes on every poll. Keep the first line, capped.
  cmd_summary=$(printf '%s' "$cmd" | head -1 | cut -c1-200)

  # detect tmux pane (always check regardless of term_pid)
  tmux_pane=""
  raw_pane=$(tr '\0' '\n' < /proc/$pid/environ 2>/dev/null | grep '^TMUX_PANE=' | cut -d= -f2 || echo "")
  if [ -n "$raw_pane" ]; then
    # Resolve %N pane id to window.pane format for cross-window targeting
    tmux_pane=$(tmux list-panes -a -F '#{pane_id} #{window_index}.#{pane_index}' 2>/dev/null | awk -v id="$raw_pane" '$1==id {print $2}')
    [ -z "$tmux_pane" ] && tmux_pane="$raw_pane"
  fi

  sessions+=("$(jq -nc \
    --argjson pid "$pid" \
    --arg repo "$repo_name" \
    --arg cwd "$cwd" \
    --arg agent "$agent_type" \
    --arg status "$status" \
    --argjson stale "$stale" \
    --arg window_addr "$window_addr" \
    --arg tmux_pane "$tmux_pane" \
    --arg cmd "$cmd_summary" \
    '{pid: $pid, repo: $repo, cwd: $cwd, agent: $agent, status: $status,
      stale: $stale, window_addr: $window_addr, tmux_pane: $tmux_pane, cmd: $cmd}')")
done

# --- worktrees ---
# Collect every agent cwd once; the attachment check below is a lookup, not a
# fresh pgrep sweep per worktree.
agent_cwds=$'\n'
for spid in $(pgrep -x "claude|opencode" 2>/dev/null || true); do
  spid_cwd=$(readlink /proc/$spid/cwd 2>/dev/null || echo "")
  [ -n "$spid_cwd" ] && agent_cwds+="$spid_cwd"$'\n'
done

# Ask git what the worktrees are rather than guessing from the directory
# layout. Globbing $root/*/ only ever saw repos exactly one level down, so a
# worktree parked inside its own repo -- .plax/worktrees/<name>, a common
# convention for agent tooling -- was invisible, and a plain clone was listed
# as a "worktree" it never was.
declare -A SEEN_WORKTREE
worktrees=()

add_worktree() {
  local path="$1" branch="$2" label="$3" parent="$4" is_main="$5"
  [ -n "$path" ] || return 0
  [ -n "${SEEN_WORKTREE[$path]:-}" ] && return 0
  [ -d "$path" ] || return 0          # git lists prunable entries too
  SEEN_WORKTREE["$path"]=1

  local dirty session_attached=false
  dirty=$(git -C "$path" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  case "$agent_cwds" in
    *$'\n'"$path"$'\n'*) session_attached=true ;;
  esac

  # `parent` and `main` exist so the list can be grouped by repository rather
  # than sorted by label: eai-2 and eai/dev1087 are both worktrees of eai, and
  # only sit next to it alphabetically by luck.
  worktrees+=("$(jq -nc \
    --arg repo "$label" \
    --arg path "$path" \
    --arg branch "$branch" \
    --arg parent "$parent" \
    --argjson main "$is_main" \
    --argjson dirty "$dirty" \
    --argjson session_attached "$session_attached" \
    '{repo: $repo, path: $path, branch: $branch, parent: $parent, main: $main,
      dirty: $dirty, session_attached: $session_attached}')")
}

while IFS= read -r root; do
  [ -n "$root" ] || continue
  case "$root" in
    "~") root="$HOME" ;;
    "~/"*) root="$HOME/${root#\~/}" ;;
  esac
  [ -d "$root" ] || continue

  for d in "$root"/*/; do
    d="${d%/}"
    [ -d "$d" ] || continue
    [ -d "$d/.git" ] || [ -f "$d/.git" ] || continue

    # `git worktree list --porcelain` emits a blank-line-separated record per
    # worktree: "worktree <path>", then "branch refs/heads/<name>", "detached",
    # or "bare". The first record is always the main worktree, which is what a
    # nested worktree gets named after.
    wt_path=""; wt_branch=""; main_repo=""; main_path=""
    while IFS= read -r line; do
      case "$line" in
        "worktree "*) wt_path="${line#worktree }"
                      if [ -z "$main_path" ]; then
                        main_path="$wt_path"; main_repo=$(basename "$wt_path")
                      fi ;;
        "branch refs/heads/"*) wt_branch="${line#branch refs/heads/}" ;;
        "detached")   wt_branch="(detached)" ;;
        "bare")       wt_path="" ;;
        "")           if [ -n "$wt_path" ]; then
                        # Top-level worktrees keep their bare name; anything
                        # nested is prefixed so it is obvious what it belongs to.
                        if [ "$(dirname "$wt_path")" = "$root" ]; then
                          wt_label="$(basename "$wt_path")"
                        else
                          wt_label="$main_repo/$(basename "$wt_path")"
                        fi
                        if [ "$wt_path" = "$main_path" ]; then is_main=true; else is_main=false; fi
                        add_worktree "$wt_path" "$wt_branch" "$wt_label" "$main_repo" "$is_main"
                      fi
                      wt_path=""; wt_branch="" ;;
      esac
    done < <(git -C "$d" worktree list --porcelain 2>/dev/null; echo)
  done
# printf '%s\n' matters: without the trailing newline `read` drops the last
# root, since it returns non-zero on an unterminated final line.
done < <(printf '%s\n' "$WORKTREE_ROOTS" | tr ':' '\n')

# jq -s over an empty stream yields [], so both arrays are always well formed.
jq -n \
  --argjson sessions "$(printf '%s\n' ${sessions[@]+"${sessions[@]}"} | jq -sc '.')" \
  --argjson worktrees "$(printf '%s\n' ${worktrees[@]+"${worktrees[@]}"} | jq -sc 'sort_by([.parent, (if .main then 0 else 1 end), .repo])')" \
  '{sessions: $sessions, worktrees: $worktrees}'
