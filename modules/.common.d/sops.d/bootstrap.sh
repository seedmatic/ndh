set -eu

# shellcheck disable=SC1091
source @nixBashTrampoline@

# A machine's age identity comes from the operator's keyring (docs/ssh-keys-architecture.adoc): nothing
# here generates or copies one. A missing identity is a loud fault, and the unit that needs it waits for
# the operator to place it.

key_file="@keyFile@"
key_dir="$(dirname "$key_file")"
public_key_file="@publicKeyFile@"
public_key_dir="$(dirname "$public_key_file")"
export_public_key_on_activation="@exportPublicKeyOnActivation@"
nixos_import_from_host="@nixosImportFromHost@"
# 1 on a NixOS guest, where the keyFile belongs to root alone; 0 on darwin, where it may be the
# operator's own file, read by their sops too.
enforce_root_key_mode="@enforceRootKeyMode@"

import_key_from_candidates() {
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    if [ -s "$candidate" ]; then
      install -d -m 700 "$key_dir"
      candidate_sum="$(sha256sum "$candidate")"
      key_sum=""
      if [ -s "$key_file" ]; then key_sum="$(sha256sum "$key_file")"; fi
      if [ "${candidate_sum%% *}" != "${key_sum%% *}" ]; then
        install -m 0400 "$candidate" "$key_file"
        echo "[sops-age-bootstrap] imported the host-provided age key from $candidate into $key_file"
      else
        echo "[sops-age-bootstrap] host key candidate $candidate matches current $key_file"
      fi
      return 0
    fi
  done <<'EOF'
@nixosHostKeyImportCandidates@
EOF

  return 1
}

if [ "${NIXOS_INSTALL_BOOTLOADER:-}" = "1" ]; then
  echo "[sops-age-bootstrap] image build activation context detected (NIXOS_INSTALL_BOOTLOADER=1); skipping key enforcement"
  exit 0
fi

if [ "$nixos_import_from_host" = "1" ]; then
  import_key_from_candidates || true
fi

if [ ! -s "$key_file" ]; then
  echo "[sops-age-bootstrap] ERROR: no age identity at $key_file" >&2
  echo "[sops-age-bootstrap] it comes from the operator's keyring and is never generated here." >&2
  echo "[sops-age-bootstrap] place it there (root, mode 0400), then run: ndh-identity-reload" >&2
  exit 1
fi

if [ "$enforce_root_key_mode" = "1" ]; then
  # umask applies only when a file is created, so a key restored over an existing file keeps that
  # file's mode: set it every time.
  if ! chown root:root "$key_file" || ! chmod 0400 "$key_file"; then
    echo "[sops-age-bootstrap] ERROR: cannot set $key_file to root:root 0400" >&2
    exit 1
  fi
fi

if [ "$export_public_key_on_activation" = "1" ]; then
  install -d -m 755 "$public_key_dir"
  age-keygen -y "$key_file" > "$public_key_file"
  chmod 644 "$public_key_file"
  echo "[sops-age-bootstrap] published host age recipient to $public_key_file"
fi
