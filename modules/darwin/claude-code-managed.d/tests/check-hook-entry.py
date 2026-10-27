#!/usr/bin/env python3
"""Checks the rendered managed settings' deny hook: every PreToolUse Bash hook blocks on failure and is synchronous,
since a hook that times out, crashes or prints garbage otherwise lets the call through (measured, Claude Code 2.1.308)."""
import json
import sys

hooks = [h for entry in json.load(open(sys.argv[1]))["hooks"]["PreToolUse"] if entry.get("matcher") == "Bash"
         for h in entry["hooks"]]
bad = [h for h in hooks if h.get("onFailure") != "block" or h.get("async") or not 0 < h.get("timeout", 0) <= 60]
print(f"{sys.argv[1]}: bash hooks={len(hooks)} not failing closed={len(bad)} {bad}")
sys.exit(1 if bad or not hooks else 0)
