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
rules = [r[5:-1] for r in json.load(open(path))["permissions"]["deny"]]


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
        "kubectl -n prod delete pod x", "kubectl --context c apply -f m.yaml", "helm -n ks upgrade r c",
        "pulumi -C infra up --yes", "incus --project p stop n1", "incus --project p exec n1 -- ls",
        "home-manager --flake . switch", "sudo nixos-rebuild --flake .#h boot",
        "sudo darwin-rebuild --rollback", "flox activate -- kubectl -n x apply -f y",
        "flox activate -d . -- incus --project p rm n1",
    ],
    "aliases": [
        "helm del r", "helm delete r", "helm un r", "helm -n x uninstall r", "helm -n x un r",
        "pulumi update --yes", "pulumi -C infra update", "pulumi down", "pulumi dn --yes",
        "pulumi --cwd infra down",
    ],
    "draft forms": [
        "kubectl apply -f y", "kubectl delete", "incus delete c1", "incus rm c1",
        "incus config set c1 k v", "incus storage volume delete p v", "incus config device add c1 d disk",
        "nixos-rebuild switch --flake .#h", "darwin-rebuild --rollback", "sudo darwin-rebuild switch",
        "rm -rf build", "mv ~/.claude /tmp/x", "flox activate -- pulumi up",
        "flox activate -d . -- pulumi destroy",
    ],
}
open_cases = 0
for group, cmds in must_refuse.items():
    left = [c for c in cmds if not refused(c)]
    open_cases += len(left)
    print(f"{group}: {len(cmds) - len(left)}/{len(cmds)} refused by the list", *(f"  OPEN {c}" for c in left), sep="\n")

read_only = [
    "kubectl get pod delete-me", "kubectl auth can-i delete pods", "kubectl -n x get pods",
    "kubectl get events --field-selector reason=Created", "kubectl get cm apply-config -o yaml",
    "kubectl explain deployment --recursive", "helm template r ch --set install.crds=true",
    "helm list -A", "helm history upgrade-test", "pulumi preview --diff",
    "pulumi stack output upstream-url", "pulumi stack ls", "pulumi config get update-window",
    "incus list", "incus info shell-box", "incus info init-node", "incus list starter",
    "incus config show c1 --expanded", "incus image list images: copyright",
    "incus list --columns ns4 restarted", "incus network list --format csv",
    "nixos-rebuild build --flake .#bioskop", "nixos-rebuild dry-build --flake .#bioskop",
    "sudo nixos-rebuild build --flake .#test-host", "darwin-rebuild build --flake .#nikopol",
    "home-manager generations", "home-manager news --flake . switchboard",
]
fps = [(c, refused(c)) for c in read_only]
fps = [(c, hit) for c, hit in fps if hit]
print(f"false positives: {len(fps)}/{len(read_only)} read-only commands refused")
for c, hit in fps:
    print(f"  FP  {c!r:52} ← {hit[0]!r}")
sys.exit(1 if open_cases or fps or missing or len(rules) != len(set(rules)) else 0)
