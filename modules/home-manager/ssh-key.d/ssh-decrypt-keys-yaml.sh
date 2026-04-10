#!/usr/bin/env -S bash -euo pipefail
# @codebase
# Decrypt SOPS-encrypted SSH keys YAML into runtime path for Home Manager activation.

source @bashTrampoline@
source @logger@

main() {
  local encrypted_yaml="$1"
  local decrypted_yaml="$2"
  local target_user="${3:-${USER:-}}"

  if [[ ! -r "$encrypted_yaml" ]]; then
    echo "missing or unreadable encrypted SSH keys YAML: $encrypted_yaml" >&2
    return 1
  fi

  local out_dir
  out_dir="$(dirname "$decrypted_yaml")"

  if [[ "$(id -u)" -eq 0 && -n "$target_user" ]]; then
    local target_group
    target_group="$(id -gn "$target_user" 2>/dev/null || echo "$target_user")"
    install -o "$target_user" -g "$target_group" -m 0700 -d "$out_dir"
  else
    install -m 0700 -d "$out_dir"
  fi

  local tmp_out
  tmp_out="$(mktemp)"
  trap 'rm -f "$tmp_out"' EXIT

  @sopsBin@ --decrypt --input-type=yaml --output-type=yaml "$encrypted_yaml" >"$tmp_out"

  if [[ "$(id -u)" -eq 0 && -n "$target_user" ]]; then
    local target_group
    target_group="$(id -gn "$target_user" 2>/dev/null || echo "$target_user")"
    install -o "$target_user" -g "$target_group" -m 0400 "$tmp_out" "$decrypted_yaml"
  else
    install -m 0400 "$tmp_out" "$decrypted_yaml"
  fi
}

ndh::logger:command:run "@loggerTag@" main "$@"
