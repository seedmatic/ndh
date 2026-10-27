#!/usr/bin/env python3
"""Checks a managed-settings deny list: twin uniformity, gap-A and alias coverage BY THE LIST
ALONE, and false positives on read-only commands.

Matching EMULATES the documented semantics (code.claude.com/docs/en/permissions, "Wildcard
patterns"): `*` matches any text including spaces; everything else is literal; a trailing ` *`
that is the rule's only wildcard also matches the bare command. It is not Claude Code's matcher —
compound splitting and wrapper stripping are left out, every input here is one simple command.
"""
import json
import re
import sys

path = sys.argv[1]
settings = json.load(open(path))["permissions"]
rules = [r[5:-1] for r in settings["deny"] if r.startswith("Bash(")]
# Path rules (verbs.json list_path_rules) are not commands: no twins, an absolute `//` or a home `~/` path only.
path_rules = [r for r in settings["deny"] if not r.startswith(("Bash(", "mcp__", "WebFetch("))]
fetch_rules = [r for r in settings["deny"] if r.startswith("WebFetch(")]
bad_fetches = [r for r in fetch_rules if not re.fullmatch(r"WebFetch\(domain:[A-Za-z0-9.-]+\)", r)]
print(f"{path}: fetch-rules={len(fetch_rules)} malformed={len(bad_fetches)} {bad_fetches}")
tool_rules = [r for r in settings["deny"] + settings.get("ask", []) if r.startswith("mcp__")]
bad_tools = [r for r in tool_rules if not re.fullmatch(r"mcp__[A-Za-z0-9_]+__[A-Za-z0-9]+", r)]
print(f"{path}: tool-rules={len(tool_rules)} malformed={len(bad_tools)} {bad_tools}")
bad_paths = [r for r in path_rules if not re.fullmatch(r"(Read|Edit)\((?://|~/)(?:[^()\s]| (?=\S))+\)", r)]
print(f"{path}: path-rules={len(path_rules)} malformed={len(bad_paths)} {bad_paths}")
ask_rules = [r[5:-1] for r in settings.get("ask", []) if r.startswith("Bash(")]


def matches(rule, cmd):
    rx = "^" + ".*".join(re.escape(part) for part in rule.split("*")) + "$"
    if re.match(rx, cmd, re.S):
        return True
    return rule.endswith(" *") and rule.count("*") == 1 and cmd == rule[:-2]


def refused(cmd):
    return [r for r in rules if matches(r, cmd)]


bases = [r for r in rules if not r.startswith("flox activate")]
missing = [b for b in bases
           if f"flox activate -- {b}" not in rules or f"flox activate * -- {b}" not in rules]
print(f"{path}: rules={len(rules)} bases={len(bases)} twins-missing={len(missing)} "
      f"duplicates={len(rules) - len(set(rules))}")

must_refuse = {
    "gap A": [
        "home-manager --flake . switch", "sudo nixos-rebuild --flake .#h boot",
        "sudo darwin-rebuild --rollback", "flox activate -- home-manager switch",
        "flox activate -d . -- nixos-rebuild switch",
    ],
    "draft forms": [
        "nixos-rebuild switch --flake .#h", "darwin-rebuild --rollback", "sudo darwin-rebuild switch",
        "mv ~/.claude /tmp/x", "security dump-keychain",
    ],
}
open_cases = 0
for group, cmds in must_refuse.items():
    left = [c for c in cmds if not refused(c)]
    open_cases += len(left)
    print(f"{group}: {len(cmds) - len(left)}/{len(cmds)} refused by the list", *(f"  OPEN {c}" for c in left), sep="\n")

# The lab's own gestures are the sessions' (the operator, 2026-10-27): the list refuses none of them.
lab_gestures = [
    "kubectl -n prod delete pod x", "kubectl apply -f y", "kubectl get pod delete-me", "helm -n ks upgrade r c",
    "helm uninstall r", "pulumi -C infra up --yes", "pulumi destroy", "pulumi preview --diff",
    "incus --project rke2lab exec n1 -- ls", "incus delete c1", "incus storage volume delete p v", "incus list",
    "cachix push seedmatic ./result", "attic push cluster ./result",
    "nixos-rebuild build --flake .#bioskop", "nixos-rebuild dry-build --flake .#bioskop",
    "sudo nixos-rebuild build --flake .#test-host", "darwin-rebuild build --flake .#nikopol",
    "home-manager generations", "home-manager news --flake . switchboard",
    "nix copy --to ssh-ng://bioskop-nixos ./result", "nix copy --to=ssh://nikopol-nixos ./result",
]
fps = [(c, refused(c)) for c in lab_gestures]
fps = [(c, hit) for c, hit in fps if hit]
print(f"false positives: {len(fps)}/{len(lab_gestures)} lab gestures and reads refused")
for c, hit in fps:
    print(f"  FP  {c!r:52} ← {hit[0]!r}")


def asked(cmd):
    return [r for r in ask_rules if matches(r, cmd)]


# The rm -rf asks left the list: Claude Code's built-in check guards a removal of a root itself.
not_asked = [r for r in ask_rules if r.startswith("rm ")]
print(f"ask: {len(not_asked)} rm rules in the list, none wanted", *(f"  LEFT {r}" for r in not_asked), sep="\n")
cleanup = ["rm -rf /tmp/x", "rm -rf /private/tmp/flox-sb", "rm -rf $T", "rm -rf mmcheck",
           "rm -rf repo/.scratchpad.d/topic", "rm -rf ${T:?}/out"]
caught = [c for c in cleanup if refused(c) or asked(c)]
print(f"cleanup: {len(cleanup) - len(caught)}/{len(cleanup)} left to the hook", *(f"  CAUGHT {c}" for c in caught), sep="\n")
sys.exit(1 if open_cases or fps or missing or not_asked or caught or bad_paths or bad_tools or bad_fetches or len(rules) != len(set(rules)) else 0)
