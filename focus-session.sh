#!/bin/bash
if [ -n "$1" ]; then
  # tmux session: find and focus the terminal window
  if [ -n "$2" ]; then
    hyprctl dispatch "hl.dsp.focus({ window = \"address:$2\" })" 2>/dev/null || true
  fi
  # fallback to any foot terminal if the address was stale
  addr=$(hyprctl clients -j 2>/dev/null | python3 -c "
import json,sys
for c in json.load(sys.stdin):
    if c.get('class','') in ('foot','kitty','ghostty','alacritty'):
        print(c.get('address',''))
        break
" 2>/dev/null)
  [ -n "$addr" ] && hyprctl dispatch "hl.dsp.focus({ window = \"address:$addr\" })" 2>/dev/null || true
  # switch to the specific tmux window + pane
  win="${1%%.*}"
  pane="${1##*.}"
  tmux select-window -t ":$win"
  tmux select-pane -t ".$pane"
elif [ -n "$2" ]; then
  # standalone (non-tmux) session
  hyprctl dispatch "hl.dsp.focus({ window = \"address:$2\" })"
fi
