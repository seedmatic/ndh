set -eu

# shellcheck disable=SC1091
source @nixBashTrampoline@

key_file="@keyFile@"
key_dir="$(dirname "$key_file")"
public_key_file="@publicKeyFile@"
public_key_dir="$(dirname "$public_key_file")"
export_public_key_on_activation="@exportPublicKeyOnActivation@"
nixos_import_from_host="@nixosImportFromHost@"
phase="@phase@"

import_key_from_candidates() {
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    if [ -s "$candidate" ]; then
      install -d -m 700 "$key_dir"
      if [ ! -s "$key_file" ]; then
        cp "$candidate" "$key_file"
        chmod 600 "$key_file"
        echo "[sops-age-bootstrap] imported host age key from $candidate into $key_file"
      else
        candidate_sum="$(sha256sum "$candidate")"
        candidate_sum="${candidate_sum%% *}"
        key_sum="$(sha256sum "$key_file")"
        key_sum="${key_sum%% *}"
        if [ "$candidate_sum" != "$key_sum" ]; then
          cp "$candidate" "$key_file"
          chmod 600 "$key_file"
          echo "[sops-age-bootstrap] refreshed age key from $candidate into $key_file (checksum changed)"
        else
          echo "[sops-age-bootstrap] host key candidate $candidate matches current $key_file"
        fi
      fi
      return 0
    fi
  done <<'EOF'
@nixosHostKeyImportCandidates@
EOF

  return 1
}

if [ "$phase" = "bootstrap" ]; then
  darwin_user_key_file="@darwinUserKeyFile@"
  import_existing_user_key_on_bootstrap="@importExistingUserKeyOnBootstrap@"

  if [ "$nixos_import_from_host" = "1" ]; then
    import_key_from_candidates || true
  fi

  if [ ! -s "$key_file" ]; then
    install -d -m 700 "$key_dir"
    if [ "$import_existing_user_key_on_bootstrap" = "1" ] && [ "$darwin_user_key_file" != "$key_file" ] && [ -s "$darwin_user_key_file" ]; then
      cp "$darwin_user_key_file" "$key_file"
      chmod 600 "$key_file"
      echo "[sops-age-bootstrap] installed existing user age key into $key_file"
    elif [ "$nixos_import_from_host" = "1" ] && import_key_from_candidates; then
      : "[sops-age-bootstrap] bootstrap imported host-provided key"
    else
      age-keygen -o "$key_file"
      chmod 600 "$key_file"
      echo "[sops-age-bootstrap] generated age key at $key_file"
    fi
  else
    echo "[sops-age-bootstrap] existing age key detected at $key_file"
  fi
else
  if [ "${NIXOS_INSTALL_BOOTLOADER:-}" = "1" ]; then
    echo "[sops-age-bootstrap] image build activation context detected (NIXOS_INSTALL_BOOTLOADER=1); skipping key enforcement"
    exit 0
  fi

  if [ "$nixos_import_from_host" = "1" ]; then
    import_key_from_candidates || true
  fi

  if [ ! -s "$key_file" ]; then
    echo "[sops-age-bootstrap] ERROR: missing SOPS age key at $key_file"
    echo "[sops-age-bootstrap] either provision the key manually or run one activation with ndh.sopsAgeKeyBootstrap.phase=\"bootstrap\""
    exit 1
  fi
fi

if [ "$export_public_key_on_activation" = "1" ] && [ -s "$key_file" ]; then
  install -d -m 755 "$public_key_dir"
  age-keygen -y "$key_file" > "$public_key_file"
  chmod 644 "$public_key_file"
  echo "[sops-age-bootstrap] published host age recipient to $public_key_file"
fi