#!/bin/bash

if [ "$1" = "tmux-new" ]; then
  # find any foot terminal, focus it, create a new tmux window
  addr=$(hyprctl clients -j 2>/dev/null | python3 -c "
import json,sys
for c in json.load(sys.stdin):
    if c.get('class','') in ('foot','kitty','ghostty','alacritty'):
        print(c.get('address',''))
        break
" 2>/dev/null)
  [ -n "$addr" ] && hyprctl dispatch "hl.dsp.focus({ window = \"address:$addr\" })" 2>/dev/null
  tmux new-window -c "${2:-$HOME}"
elif [ -n "$1" ]; then
  # tmux session: find and focus the terminal window
  if [ -n "$2" ]; then
    hyprctl dispatch "hl.dsp.focus({ window = \"address:$2\" })" 2>/dev/null || true
  fi
  addr=$(hyprctl clients -j 2>/dev/null | python3 -c "
import json,sys
for c in json.load(sys.stdin):
    if c.get('class','') in ('foot','kitty','ghostty','alacritty'):
        print(c.get('address',''))
        break
" 2>/dev/null)
  [ -n "$addr" ] && hyprctl dispatch "hl.dsp.focus({ window = \"address:$addr\" })" 2>/dev/null || true
  win="${1%%.*}"
  pane="${1##*.}"
  tmux select-window -t ":$win"
  tmux select-pane -t ".$pane"
elif [ -n "$2" ]; then
  # standalone (non-tmux) session
  hyprctl dispatch "hl.dsp.focus({ window = \"address:$2\" })"
fi
