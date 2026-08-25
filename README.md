# Agent Cockpit (`apollo.sessions`)

An Omarchy bar widget that lists live Claude and Opencode sessions with their
blocked/working state, plus the status of every git worktree under
`~/Work/repos`.

| Key | Action |
| --- | --- |
| `j` / `k` | move the selection |
| `Enter` | focus a session's tmux pane, or open a worktree in a new terminal |
| `t` | focus the tmux terminal (opening a new window for a worktree) |
| `Tab` | switch to the neighbouring bar panel |
| `Esc` | close |

## Files

- `BarWidget.qml` — bar entry point; polls `session-poll.sh` on a timer
- `Panel.qml` — the keyboard-driven popout
- `session-poll.sh` — emits the JSON the widget renders
- `focus-session.sh` — moves Hyprland focus and drives tmux

## Development

**Editing a `.qml` file requires `omarchy restart shell`.** Quickshell watches
its own config path (`/usr/share/omarchy/shell`), not
`~/.config/omarchy/plugins`, so plugin QML is read once at shell startup and
saved changes do not take effect on their own. Neither hot-reload nor
`omarchy-shell shell rescanPlugins` picks them up — both were measured against
a deliberately altered timer interval and neither applied it.

The shell scripts are different: they are re-read on every invocation, so
`focus-session.sh` and `session-poll.sh` edits apply immediately.

This asymmetry is worth remembering, because it looks exactly like a bug in
the code you just changed. See
[#1](https://github.com/apollopower/omarchy-agent-cockpit/issues/1).

To check the current shell against your working tree:

```bash
ps -eo pid,lstart,cmd | grep quickshell   # started before your last edit?
```
