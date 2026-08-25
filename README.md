# Agent Cockpit

An Omarchy bar widget for people who run several coding agents at once. The bar
shows how many sessions are live and how many are waiting on you; the panel
tells you which ones, and jumps you straight to the right tmux pane.

![Agent Cockpit panel](preview.png)

The bar badge reads `blocked/total` when something needs you, and just `total`
otherwise.

## Install

```bash
omarchy plugin add https://github.com/apollopower/omarchy-agent-cockpit --enable
```

## Keys

| Key | Action |
| --- | --- |
| `j` / `k` | move the selection |
| `Enter` | on a session, focus its exact tmux pane; on a worktree, open it in a terminal |
| `t` | focus the tmux terminal, opening a new window for a worktree |
| `Tab` | switch to the neighbouring bar panel |
| `Esc` | close |

## Configuration

Set these under the widget's entry in `~/.config/omarchy/shell.json`:

| Setting | Default | Meaning |
| --- | --- | --- |
| `refreshIntervalSec` | `10` | how often to poll (minimum 5) |
| `stuckAfterSec` | `600` | how long a mid-loop session may go without progress before it is called stuck (minimum 60) |
| `worktreeRoots` | `~/Work/repos` | colon-separated directories whose immediate git repos are listed |
| `terminal` | *(empty)* | terminal used to open a worktree outside tmux; empty means `$TERMINAL`, then the first of alacritty, foot, kitty, ghostty that is installed |

## What the states mean

The bar shows a `>_` icon whenever agent sessions are running. It stays the
same colour as its neighbours until one of them is **blocked**, and then shifts
to your theme's urgent colour. Nothing appears, nothing counts up.

| State | Icon | What it actually means |
| --- | --- | --- |
| **Blocked** | question mark, urgent | The agent asked you something and stopped. **The only state that needs you now**, and the only one that colours the bar. |
| **Working** | arrows, accent | Mid agent loop. Stays working through a long tool call. |
| **Idle** | dot, dim | The turn ended. It might be finished, it might be waiting — that is not knowable, so nothing is claimed. |
| **Stuck** | warning, urgent | Claims to be mid-loop but has not moved in `stuckAfterSec`. Usually a killed session. |

"Blocked" is deliberately narrow. Earlier versions called any quiet session
blocked, which meant a long `cargo build` looked identical to an agent waiting
on you.

### Where the signal comes from

**Opencode** records a question as a `question` tool part still in the
`running` state, and every assistant message records how its turn ended
(`tool-calls` mid-loop, `stop` / `unknown` / `length` / absent for a finished
turn — absent meaning aborted). Both are read from its SQLite store, scoped to
the newest message per directory: an abandoned session can leave a `running`
question outstanding for days.

**Claude Code** records an unanswered `AskUserQuestion` or `ExitPlanMode` tool
call, and `stop_reason` on the last assistant entry (`end_turn` vs `tool_use`).
Both come from the session transcript under `~/.claude/projects/`; only the
tail is read, since transcripts reach megabytes.

### What it cannot tell you

- **A plain-text question reads as Idle.** An agent that ends its turn with
  "shall I proceed?" is indistinguishable from one that finished the job.
  Blocked has false negatives by design.
- **A permission prompt is invisible.** An unanswered `bash` tool call looks
  the same whether the command is running or waiting for your approval. Neither
  agent records the difference.
- **Two instances of the same agent in one directory share a reading**, because
  state is keyed by working directory. Two *different* agents in the same
  directory are tracked separately.

## Requirements

Omarchy's Quickshell bar and Hyprland. Beyond that: `jq`, `python3`, `git` and
`hyprctl`, all present on a stock Omarchy install. `tmux` is needed for pane
focusing and the `t` key. `sqlite3` is needed for Opencode status — without it
Opencode sessions fall back to the Claude transcript heuristic.

Nothing is written outside the plugin directory, so removal is just
`omarchy plugin remove apollo.agent-cockpit`.

## Files

- `BarWidget.qml` — bar entry point; polls `session-poll.sh` on a timer
- `Panel.qml` — the keyboard-driven popout
- `session-poll.sh` — emits the JSON the widget renders
- `focus-session.sh` — moves Hyprland focus and drives tmux
- `agent-state.py` — reads a Claude transcript tail and reports its state

## Development

**Editing a `.qml` file requires `omarchy restart shell`.** Quickshell watches
its own config path (`/usr/share/omarchy/shell`), not
`~/.config/omarchy/plugins`, so plugin QML is read once at shell startup and
saved changes do not take effect on their own. Neither hot-reload nor
`omarchy-shell shell rescanPlugins` picks them up — both were measured against
a deliberately altered timer interval and neither applied it.

The shell scripts are different: they are re-read on every invocation, so
`focus-session.sh` and `session-poll.sh` edits apply immediately.

This asymmetry is worth remembering, because it looks exactly like a bug in the
code you just changed. See
[#1](https://github.com/apollopower/omarchy-agent-cockpit/issues/1).

To check the running shell against your working tree:

```bash
ps -eo pid,lstart,cmd | grep quickshell   # started before your last edit?
```

## License

MIT — see [LICENSE](LICENSE).
