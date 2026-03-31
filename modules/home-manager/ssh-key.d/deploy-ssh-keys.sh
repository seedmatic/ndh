source @activationLogger@

main() {
  set -euo pipefail

  keys_yaml="@keysYaml@"
  if [[ ! -r "$keys_yaml" ]]; then
    echo "SSH keys YAML file not readable: $keys_yaml" >&2
    return 0
  fi

  tmp_keys_dir="$(@mktemp@ -d)"
  tmp_output_yaml="$(@mktemp@)"
  trap 'rm -rf "$tmp_keys_dir" "$tmp_output_yaml"' EXIT

  : "Generate keys & certificates using ssh-generate-keys-yaml.sh"
  @bash@ @sshGenerateKeysYaml@ "@profileName@" "$(@hostname@ -s)" "$keys_yaml" "$tmp_output_yaml" "@hostsCatalogCsv@" 2>/dev/null || {
    echo "Failed to generate keys and certificates" >&2
    return 1
  }

  : "Extract all key/cert files to deployment directory"
  @bash@ @sshExtractKeys@ "$tmp_output_yaml" "$tmp_keys_dir"

  # Generate agent-keys manifest AFTER extraction so it is never touched by ssh-extract-keys.sh.
  # Only list keys that have their own private key material (guards against cert-only entries like 'host').
  # Include ssh-authority keys: mammoth-skate is both the CA and the personal bioskop identity.
  @yq@ eval -r '
    to_entries[]
    | select(.value | has("private"))
    | select(
        ((.value.usage // []) | join(",") | test("(^|,)(agent-signing|user-signing|ssh-user|ssh-authority)(,|$)"))
        or
        (((.value.authorities // {}) | to_entries | map((.value.usage // []) | join(",")) | join(","))
          | test("(^|,)(ssh-user)(,|$)"))
      )
    | .key
  ' "$tmp_output_yaml" > "$tmp_keys_dir/agent-keys"

  keys_state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/ssh-key.d"
  install -d -m 700 "$keys_state_dir"
  @rsync@ -avL \
    --checksum \
    --delete \
    --chmod=u+w,go-r \
    --chown=$(id -un):$(id -gn) \
    "$tmp_keys_dir"/ "$keys_state_dir"/ || true

  # Defensive cleanup: if <key>-cert.pub does not match the private key, remove it.
  # ssh-add auto-loads matching sidecars; stale mismatches generate warnings.
  if command -v ssh-keygen >/dev/null 2>&1; then
    agent_keys_file="$keys_state_dir/agent-keys"
    if [[ -r "$agent_keys_file" ]]; then
      while IFS= read -r key_name; do
        [[ -n "$key_name" ]] || continue
        local_key="$keys_state_dir/$key_name"
        local_cert="$local_key-cert.pub"
        if [[ -f "$local_key" && -f "$local_cert" ]]; then
          key_fp="$(ssh-keygen -lf "$local_key" 2>/dev/null | @awk@ '{print $2}' || true)"
          cert_fp="$(ssh-keygen -Lf "$local_cert" 2>/dev/null | @awk@ '/Public key:/ {print $4; exit}' || true)"
          if [[ -n "$key_fp" && -n "$cert_fp" && "$key_fp" != "$cert_fp" ]]; then
            rm -f "$local_cert"
          fi
        fi
      done < "$agent_keys_file"
    fi
  fi
}

activation_run "@activationTag@" main "$@"
