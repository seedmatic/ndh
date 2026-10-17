#!/usr/bin/env python3
"""Validates the deletion areas security engraves (owned-dirs.json): the build fails on a registry the hook would
apply too widely. Every owned and worktree pattern lies under an allowed root and below it; a pattern directly
under /private/tmp names at least 3 characters before any wildcard; no pattern belongs to two sessions; every
session names its conversations; a session's workspace, when engraved, is absolute, under the worktree store or the
home."""
import json
import re
import sys

ALLOWED_ROOTS = ("~/.claude/.scratchpad.d/", "/private/tmp/", "/Volumes/git-worktree-store/")


def expand(pattern):
    m = re.search(r"\{([^{}]*)\}", pattern)
    if not m:
        return [pattern]
    body = m.group(1)
    rng = re.fullmatch(r"(\d+)\.\.(\d+)", body)
    alts = [str(i) for i in range(int(rng.group(1)), int(rng.group(2)) + 1)] if rng else body.split(",")
    return [x for a in alts for x in expand(pattern[:m.start()] + a + pattern[m.end():])]


registry = json.load(open(sys.argv[1]))
errors, owners = [], {}
for name, session in registry.get("sessions", {}).items():
    if not session.get("conversations"):
        errors.append(f"{name}: no conversation id, so no session could ever use its areas")
    workspace = session.get("workspace")
    if workspace is not None and not (isinstance(workspace, str) and re.fullmatch(r"(?:~|/Volumes/git-worktree-store)(?:/[^/\s]+)+", workspace)):
        errors.append(f"{name}: workspace {workspace!r} is not an absolute path under /Volumes/git-worktree-store/ or ~")
    for key in ("owned", "worktrees"):
        for raw in session.get(key, []):
            for pattern in expand(raw):
                root = next((r for r in ALLOWED_ROOTS if pattern.startswith(r)), None)
                rest = pattern[len(root):] if root else ""
                if root is None or not rest or rest.startswith(("*", "/")):
                    errors.append(f"{name}: {pattern} is not strictly below one of {', '.join(ALLOWED_ROOTS)}")
                elif root == "/private/tmp/" and len(re.split(r"[*?\[]", rest, maxsplit=1)[0]) < 3:
                    errors.append(f"{name}: {pattern} names fewer than 3 characters under /private/tmp")
                if pattern in owners and owners[pattern] != name:
                    errors.append(f"{pattern} belongs to both {owners[pattern]} and {name}")
                owners[pattern] = name
print(f"{sys.argv[1]}: sessions={len(registry.get('sessions', {}))} patterns={len(owners)} errors={len(errors)}")
for e in errors:
    print(f"  {e}")
sys.exit(1 if errors else 0)
