#!/usr/bin/env bash
# PreToolUse hook on Bash: refuse a nix command that would evaluate a WORKING TREE.
#
# The global git sops smudge decrypts the secrets on disk, and any evaluation that names a checkout (`.`, `.#x`, a
# path, a `git+file:` without `rev=`, or no installable at all, which means `.`) copies that tree — plaintext secrets
# included — into the store, from where the cache publishes it. That is the 2026-10-10 leak. A revision is fetched
# from the object database, where the secrets are encrypted, so `git+file://…?rev=<sha>` and pushed refs are safe.
# A rule a session has to remember was not enough; this one is refused before it runs.
set -euo pipefail

command="$(jq -r '.tool_input.command // ""')"

refuse() {
  jq -n --arg r "$1" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
  exit 0
}

# A flake reference is unsafe when it resolves to a directory on disk without naming a revision.
unsafe_ref() {
  local ref="${1%%#*}"
  ref="${ref%%^*}"
  [[ "$ref" == *rev=* ]] && return 1
  case "$ref" in
    /nix/store/* | path:/nix/store/*) return 1 ;;
    "" | . | .. | ./* | ../* | /* | '~'* | path:* | git+file:* | file:* | '$'*) return 0 ;;
  esac
  return 1
}

why="Refused: this nix command evaluates a working tree, and a decrypted checkout copies its secrets into the store in clear (the 2026-10-10 leak). Name a revision instead: nix <cmd> \"git+file://\$PWD?rev=\$(git rev-parse HEAD)#<attr>\", or a pushed github: ref. Offending reference:"

# Options whose next word is a value, not an installable.
takes_value=" --arg --argstr --option --override-input --inputs-from --profile -o --out-link --apply --system --max-jobs -j --to --from --store --eval-store --cores --keep-failed-in --log-format --builders --reference-lock-file --output-lock-file --update-input "

check_nix() { # $@ = the words after `nix`
  local sub="" sub2="" w first=1 positional=() expr=0 i=0 words=("$@")
  while ((i < ${#words[@]})); do
    w="${words[i]}"
    case "$w" in
      --) break ;;
      -c | --command) break ;;
      --expr | -f | --file | --impure-expr) expr=1 ;;
      --override-input)
        unsafe_ref "${words[i + 2]:-}" && refuse "$why --override-input ${words[i + 1]:-} ${words[i + 2]:-}"
        i=$((i + 3))
        continue
        ;;
      --inputs-from | --reference-lock-file)
        unsafe_ref "${words[i + 1]:-}" && refuse "$why $w ${words[i + 1]:-}"
        ;;
    esac
    if [[ "$w" == -* ]]; then
      [[ "$takes_value" == *" $w "* ]] && i=$((i + 1))
    elif [[ -z "$sub" ]]; then
      sub="$w"
    elif [[ "$sub" == flake && -z "$sub2" ]]; then
      sub2="$w"
    else
      positional+=("$w")
    fi
    i=$((i + 1))
  done
  ((expr)) && return 0
  case "$sub" in
    build | run | develop | shell | eval | fmt | bundle | print-dev-env | path-info | why-depends | search | edit | repl | copy) ;;
    flake)
      case "$sub2" in
        check | show | metadata | info | lock | update | archive | prefetch) ;;
        *) return 0 ;;
      esac
      ;;
    *) return 0 ;;
  esac
  # `nix copy` and `nix path-info` are mostly given store paths; only a flake-looking positional matters there.
  if ((${#positional[@]} == 0)); then
    case "$sub" in copy | path-info | why-depends | search) return 0 ;; esac
    refuse "$why (none: nix $sub${sub2:+ $sub2} defaults to the current directory)"
  fi
  case "$sub" in run | eval | fmt) positional=("${positional[0]}") ;; esac
  for w in "${positional[@]}"; do
    unsafe_ref "$w" && refuse "$why $w"
  done
  return 0
}

check_rebuild() { # $@ = the words after nixos-rebuild / darwin-rebuild / home-manager
  local i=0 words=("$@")
  while ((i < ${#words[@]})); do
    if [[ "${words[i]}" == --flake ]]; then
      unsafe_ref "${words[i + 1]:-}" && refuse "$why --flake ${words[i + 1]:-}"
    fi
    i=$((i + 1))
  done
  return 0
}

# One command per line: split on the shell's separators and substitutions. Quotes are dropped from the words, so
# `"git+file://$PWD?rev=$(git rev-parse HEAD)"` is judged on its `rev=`.
while IFS= read -r segment; do
  read -ra words <<<"${segment//[\"\']/}"
  # Skip the wrappers that run their argument as a command.
  while ((${#words[@]})); do
    case "${words[0]}" in
      sudo | env | time | exec | command | nohup | builtin) words=("${words[@]:1}") ;;
      *=*) words=("${words[@]:1}") ;;
      flox)
        j=1
        while ((j < ${#words[@]})) && [[ "${words[j]}" != -- ]]; do j=$((j + 1)); done
        words=("${words[@]:j+1}")
        ;;
      *) break ;;
    esac
  done
  ((${#words[@]})) || continue
  case "${words[0]##*/}" in
    nix) check_nix "${words[@]:1}" ;;
    nixos-rebuild | darwin-rebuild | home-manager) check_rebuild "${words[@]:1}" ;;
  esac
done < <(printf '%s\n' "$command" | sed -E 's/&&|\|\||;|\||\$\(|`|\(|\)/\n/g')
exit 0
