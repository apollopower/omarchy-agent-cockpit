#!/usr/bin/env python3
"""Report what a Claude Code session is doing, from its transcript.

Usage: agent-state.py <claude-project-dir>
Prints "<state>|<epoch-seconds>", where state is one of:

  blocked  an unanswered user-facing question tool is outstanding -- the agent
           is stopped on a specific answer from the user
  idle     the last assistant turn ended (stop_reason 'end_turn'); the agent
           has stopped, but whether it finished or is waiting is unknowable
  working  the last assistant turn ended in tool use, so the loop is running
  unknown  no usable transcript

The epoch is the moment that state began, so callers can age it.

Only the tail of the newest transcript is read: these files grow to megabytes
and this runs on every poll.
"""
import json
import os
import sys

TAIL_BYTES = 256 * 1024
# Tools that stop the agent until the user answers. A plain-text question at
# the end of a turn is NOT detectable -- it looks exactly like a finished task,
# and is reported as idle.
USER_FACING = {"AskUserQuestion", "ExitPlanMode"}


def newest_transcript(directory):
    best, best_mtime = None, -1
    try:
        entries = os.scandir(directory)
    except OSError:
        return None
    with entries:
        for entry in entries:
            if not entry.name.endswith(".jsonl"):
                continue
            try:
                mtime = entry.stat().st_mtime
            except OSError:
                continue
            if mtime > best_mtime:
                best, best_mtime = entry.path, mtime
    return best


def tail_records(path):
    with open(path, "rb") as handle:
        handle.seek(0, os.SEEK_END)
        start = max(0, handle.tell() - TAIL_BYTES)
        handle.seek(start)
        blob = handle.read()
    lines = blob.split(b"\n")
    if start:
        lines = lines[1:]          # first line is probably truncated
    for line in lines:
        if not line.strip():
            continue
        try:
            yield json.loads(line)
        except ValueError:
            continue


def entry_epoch(record):
    stamp = record.get("timestamp")
    if not stamp:
        return None
    try:
        from datetime import datetime
        return datetime.fromisoformat(stamp.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def classify(records):
    issued = {}                    # tool_use id -> name
    answered = set()               # tool_use ids that got a result
    last_assistant = None
    newest_epoch = None

    for record in records:
        epoch = entry_epoch(record)
        if epoch and (newest_epoch is None or epoch > newest_epoch):
            newest_epoch = epoch
        message = record.get("message")
        if not isinstance(message, dict):
            continue
        for block in message.get("content") or []:
            if not isinstance(block, dict):
                continue
            if block.get("type") == "tool_use":
                issued[block.get("id")] = block.get("name")
            elif block.get("type") == "tool_result":
                answered.add(block.get("tool_use_id"))
        if record.get("type") == "assistant":
            last_assistant = (record, message, epoch)

    if last_assistant is None:
        return ("unknown", newest_epoch)

    record, message, epoch = last_assistant

    # An outstanding user-facing question outranks everything else: the agent
    # cannot proceed until it is answered.
    for block in message.get("content") or []:
        if not isinstance(block, dict) or block.get("type") != "tool_use":
            continue
        if block.get("name") in USER_FACING and block.get("id") not in answered:
            return ("blocked", epoch or newest_epoch)

    if message.get("stop_reason") == "end_turn":
        return ("idle", epoch or newest_epoch)
    return ("working", newest_epoch)


def main():
    directory = sys.argv[1] if len(sys.argv) > 1 else ""
    path = newest_transcript(directory) if directory else None
    if not path:
        print("unknown|0")
        return
    state, epoch = classify(tail_records(path))
    print("%s|%d" % (state, int(epoch or 0)))


if __name__ == "__main__":
    main()
