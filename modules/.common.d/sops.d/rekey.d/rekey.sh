# sops-rekey — re-seal every sops file of this repository to its creation rule's recipients, after .sops.yaml changed
# them (a recipient added or retired). The operator's gesture: `sops updatekeys` opens each file's data key with the
# operator's identity (SOPS_AGE_KEY_CMD on the seat) and seals it again; no value is decrypted to the output.
# Run from the repository's root. Refused, nothing changed: elsewhere, or a sealed file with uncommitted changes.
# After it, every sealed file's recipients are exactly its rule's, or it fails naming the file; the files are staged
# by name, for the operator to commit.

root="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "sops-rekey: not in a git repository" >&2; exit 1; }
[[ "$(pwd -P)" == "$(cd "$root" && pwd -P)" ]] || { echo "sops-rekey: run it from the repository's root, ${root}" >&2; exit 1; }
[[ -f .sops.yaml ]] || { echo "sops-rekey: no .sops.yaml here" >&2; exit 1; }

encrypted() { [[ "$(sops filestatus "$1" 2>/dev/null)" == *'"encrypted":true'* ]]; }
ruleOf() { # <file>: the age recipients of the first creation rule whose path_regex matches it, sorted
  local n i regex
  n=$(yq -r '.creation_rules | length' .sops.yaml)
  for ((i = 0; i < n; i++)); do
    regex=$(I=$i yq -r '.creation_rules[env(I)].path_regex // ""' .sops.yaml)
    if [[ -n $regex && $1 =~ $regex ]]; then
      : "a list, or one comma-separated string: sops takes both"
      I=$i yq -r '.creation_rules[env(I)].age // [] | ((select(tag == "!!str") | split(",") | .[]), (select(tag == "!!seq") | .[])) | trim' .sops.yaml | sort -u
      return 0
    fi
  done
  return 1
}
recipientsOf() { yq -r '.sops.age // [] | .[].recipient' "$1" | sort -u; }

: "every file a rule names, clean before anything: a changed one may not even read as sealed any more"
while IFS= read -r f; do
  ruleOf "$f" >/dev/null || continue
  [[ -z "$(git status --porcelain -- "$f")" ]] || { echo "sops-rekey: ${f} has uncommitted changes: commit or restore it first" >&2; exit 1; }
done < <(git ls-files)
mapfile -t files < <(git ls-files | while IFS= read -r f; do [[ -f $f ]] && encrypted "$f" && printf '%s\n' "$f"; done)
((${#files[@]} > 0)) || { echo "sops-rekey: no sealed file in this repository" >&2; exit 1; }
for f in "${files[@]}"; do
  ruleOf "$f" >/dev/null || { echo "sops-rekey: ${f} matches no creation rule" >&2; exit 1; }
done

changed=()
for f in "${files[@]}"; do
  if [[ "$(recipientsOf "$f")" == "$(ruleOf "$f")" ]]; then
    echo "current  ${f}"
    continue
  fi
  sops updatekeys -y "$f" >/dev/null 2>&1 || { echo "sops-rekey: sops updatekeys failed on ${f} (its identity, or its rule)" >&2; exit 1; }
  [[ "$(recipientsOf "$f")" == "$(ruleOf "$f")" ]] || { echo "sops-rekey: ${f} is not sealed to its rule's recipients after updatekeys" >&2; exit 1; }
  echo "re-sealed ${f}"
  changed+=("$f")
done
((${#changed[@]} > 0)) || { echo "every sealed file is sealed to its rule: nothing to do"; exit 0; }
git add -- "${changed[@]}"
echo "staged ${#changed[@]} file(s); next: git commit -m 'chore(sops): re-seal to .sops.yaml's recipients' (signed, as usual)"
