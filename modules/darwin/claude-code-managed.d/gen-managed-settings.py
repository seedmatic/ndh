#!/usr/bin/env python3
"""Generates the managed-settings deny list from deny-hook/verbs.json, the one verb table the
hook also reads.

The list is the narrow belt; the hook is the full net. A list false positive cannot be rescued —
deny rules are evaluated whatever a PreToolUse hook returns — so every rule names its verb as a
WHOLE word:

  `P V`       the bare verb — redundant beside `P V *`, but its flox twin `flox activate * -- P V`
              is what catches a bare verb under flox: `flox activate * -- P V *` has two
              wildcards, so its trailing ` *` no longer matches an empty tail
  `P V *`     the verb first (a trailing ` *` that is the only wildcard also matches bare `P V`)
  `P -* V`    an option before the verb, verb last (gap A)
  `P -* V *`  an option before the verb, words after it

Gap A is always option-shaped, so its wildcard is anchored on `-`: `P * V` would also refuse
`kubectl auth can-i delete pods`. Nested verbs (`incus config set`, `incus storage volume
delete`) and flag verbs (`--rollback`) follow a word that is not an option, so they keep `P * V`
and `P * V *`. Each base gets its two flox twins.
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
table = json.load(open(os.path.join(HERE, "deny-hook", "verbs.json")))

bases = []


def add(rule):
    if rule not in bases:
        bases.append(rule)


for prog, spec in table["programs"].items():
    if spec.get("in_list", True) is False:
        continue
    for p in [prog] + ([f"sudo {prog}"] if spec.get("sudo") else []):
        for verb in spec["verbs"]:
            add(f"{p} {verb}")
            add(f"{p} {verb} *")
            add(f"{p} -* {verb}")
            add(f"{p} -* {verb} *")
        for verb in spec.get("nested_verbs", []) + spec.get("flag_verbs", []):
            if verb.startswith("-"):
                add(f"{p} {verb}")
                add(f"{p} {verb} *")
            add(f"{p} * {verb}")
            add(f"{p} * {verb} *")
for rule in table.get("list_extra_rules", []):
    add(rule)

deny = []
for base in bases:
    deny += [f"Bash({base})", f"Bash(flox activate -- {base})", f"Bash(flox activate * -- {base})"]

out = os.path.join(HERE, sys.argv[1] if len(sys.argv) > 1 else "managed-settings.v3.json")
with open(out, "w", encoding="utf-8") as fh:
    json.dump({"permissions": {"deny": deny}}, fh, indent=2)
    fh.write("\n")
print(f"{os.path.basename(out)}: bases={len(bases)} rules={len(deny)}")
