"""no-jq: jq is replaced by yq-go in every script ndh runs (operator, 2026-10-21), but for ONE reviewed exception.

Scans every .sh and .nix under the tree given (the repo at the revision), test suites left out, and reports each
jq it USES, by owner: a store path or attribute (`${pkgs.jq}`, `pkgs.jq`, `jq` in a package list), a replaceVars
token (`@jq@`), or a bare `jq` command. A mention in a comment is not a use.

The exception (operator, 2026-10-22): store-freeze reads its manifest in the guests' INITRD with jq, paid at every
stage-1 boot (jq 71 KB, yq-go 13.6 MB, +4.2 MB on the initrd): modules/nixos/store-freeze.nix's initrdPath, and the
stage-1 script modules/nixos/store-freeze.d/stack.sh. Nothing else.

Usage: scan.py <tree> [--strict]. Report mode (default) prints what is left and exits 0; strict exits 1 on any.
"""

import os
import re
import sys

EXCEPTIONS = {
    "modules/nixos/store-freeze.nix": "the initrd's jq (initrdPath), stage 1",
    "modules/nixos/store-freeze.d/stack.sh": "stage 1 in the initrd, run with the initrd's jq",
}
# A use: a store path, an attribute, a token, or jq as a command (at a line's start, after a pipe, $( or a separator).
USE = re.compile(
    r"\$\{pkgs\.jq\}|\bpkgs\.jq\b(?!-)|@jq@|lib\.getExe pkgs\.jq\b"
    r"|(?:^|[|;&(`]|\$\()\s*jq(?=\s|$)"
    r"|^\s*jq\s*$"
)
OWNERS = [("modules/home-manager/claude-code", "🤖"), ("modules/darwin/claude-code", "🤖"), ("flake.nix", "🤖?")]


def owner(path, line):
    if path == "flake.nix":
        # The one left there is claude-code-backend-seats' check (🤖's area); any other is ❄️'s.
        return "🤖" if "claude-code" in line or "expected" in line else "❄️"
    for prefix, who in OWNERS:
        if path.startswith(prefix):
            return who
    return "❄️"


def strip_comment(line, nix):
    """The line without its comment: `#` in a .sh, `#` in a .nix (a `#` inside quotes is rare enough here)."""
    if line.lstrip().startswith("#"):
        return ""
    return re.split(r"\s#\s", line, maxsplit=1)[0] if nix else line


def main(tree, strict):
    found = []
    for root, dirs, files in os.walk(tree):
        dirs[:] = [d for d in dirs if d not in (".git", "tests", "test", ".flox-envs.d", "no-jq.d")]
        for f in files:
            if not f.endswith((".sh", ".nix")):
                continue
            full = os.path.join(root, f)
            rel = os.path.relpath(full, tree)
            for n, raw in enumerate(open(full, encoding="utf-8", errors="replace"), 1):
                code = strip_comment(raw.rstrip("\n"), f.endswith(".nix"))
                if not code or not USE.search(code):
                    continue
                if rel in EXCEPTIONS:
                    continue
                found.append((owner(rel, raw), rel, n, code.strip()))
    for rel, why in EXCEPTIONS.items():
        print(f"exception\t{rel}\t{why}")
    for who, rel, n, code in sorted(found):
        print(f"jq\t{who}\t{rel}:{n}\t{code[:110]}")
    print(f"no-jq: {len(found)} jq use(s) left outside the exception ({'strict' if strict else 'report mode'})")
    return 1 if strict and found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], "--strict" in sys.argv[2:]))
