source @activationLogger@

main() {
  set -euo pipefail

  keys_yaml="@keysYaml@"
  if [[ ! -r "$keys_yaml" ]]; then
    echo "SSH keys YAML file not readable: $keys_yaml" >&2
    return 0
  fi

  tmp_keys_dir="$(@mktemp@ -d)"
  tmp_profile_yaml="$(@mktemp@)"
  trap 'rm -rf "$tmp_keys_dir" "$tmp_profile_yaml"' EXIT

  @yq@ eval '.profiles."@profileName@"' "$keys_yaml" > "$tmp_profile_yaml"

  @bash@ @sshExtractKeys@ "$tmp_profile_yaml" "$tmp_keys_dir"

  keys_state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/ssh-keys.d"
  install -d -m 700 "$keys_state_dir"
  @rsync@ -avL \
    --checksum \
    --delete \
    --chmod=u+w,go-r \
    --chown=$(id -un):$(id -gn) \
    "$tmp_keys_dir"/ "$keys_state_dir"/ || true

  # Defensive cleanup: if host-cert.pub does not match host private key, remove it.
  # ssh-add auto-loads <key>-cert.pub sidecars; stale mismatches generate warnings.
  local_host_key="$keys_state_dir/host"
  local_host_cert="$keys_state_dir/host-cert.pub"
  if [[ -f "$local_host_key" && -f "$local_host_cert" ]] && command -v ssh-keygen >/dev/null 2>&1; then
    key_fp="$(ssh-keygen -lf "$local_host_key" 2>/dev/null | awk '{print $2}' || true)"
    cert_fp="$(ssh-keygen -Lf "$local_host_cert" 2>/dev/null | awk '/Public key:/ {print $4; exit}' || true)"
    if [[ -n "$key_fp" && -n "$cert_fp" && "$key_fp" != "$cert_fp" ]]; then
      rm -f "$local_host_cert"
    fi
  fi
}

activation_run "@activationTag@" main "$@"
