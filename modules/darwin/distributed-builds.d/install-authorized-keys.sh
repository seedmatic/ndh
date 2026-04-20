#!/usr/bin/env -S bash -euo pipefail

source @nixBashTrampoline@

main() {
  builder_pubkey="@builderPubKey@"
  keys_dir="@authorizedKeysDir@"
  keys_path="$keys_dir/@groupName@"

  mkdir -p "$keys_dir"
  chmod 755 "$keys_dir"
  chown root:wheel "$keys_dir"

  echo "[distributed-builds] installing builder authorized keys to $keys_path"

  tmpfile=$(mktemp)
  printf '%s\n' "$builder_pubkey" > "$tmpfile"
  install -m 640 -o root -g @groupName@ "$tmpfile" "$keys_path"
  chown root:@groupName@ "$keys_path"
  rm -f "$tmpfile"
}

ndh::logger:command:run darwin.activationScripts.distributed-builds.install-authorized-keys main "$@"
