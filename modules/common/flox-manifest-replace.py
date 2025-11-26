#!/usr/bin/env python3
"""Replace placeholder strings with TOML triple-quoted literals."""

import json
import pathlib
import sys

if len(sys.argv) != 3:
    raise SystemExit("Usage: flox-manifest-replace.py <replacements-json> <output-file>")

replacements_path = pathlib.Path(sys.argv[1])
out_path = pathlib.Path(sys.argv[2])

replacements = json.loads(replacements_path.read_text(encoding="utf-8"))
content = out_path.read_text(encoding="utf-8")

for repl in replacements:
    placeholder_token = '"' + repl["placeholder"] + '"'
    profile_fragment = repl["content"]
    if "'''" in profile_fragment:
        raise SystemExit(
            "profile fragments containing triple single quotes are currently unsupported"
        )
    literal = "'''\n" + profile_fragment.rstrip("\n") + "\n'''"
    if placeholder_token not in content:
        raise SystemExit(f"placeholder {repl['placeholder']} not found in manifest")
    content = content.replace(placeholder_token, literal, 1)

out_path.write_text(content, encoding="utf-8")
