set -eu

key_file="@keyFile@"
key_dir="$(dirname "$key_file")"
public_key_file="@publicKeyFile@"
public_key_dir="$(dirname "$public_key_file")"
export_public_key_on_activation="@exportPublicKeyOnActivation@"
nixos_import_from_host="@nixosImportFromHost@"
remote_fetch_enable="@remoteFetchEnable@"
remote_fetch_user="@remoteFetchUser@"
remote_fetch_key_path="@remoteFetchKeyPath@"
remote_fetch_use_sudo="@remoteFetchUseSudo@"
remote_fetch_hostname_env_var="@remoteFetchHostnameEnvVar@"
remote_fetch_mdns_suffix="@remoteFetchMdnsSuffix@"
ssh_bin="@sshBin@/bin/ssh"
sudo_bin="@sudoBin@/bin/sudo"
runuser_bin="@utilLinuxBin@/bin/runuser"
phase="@phase@"

if [ "$phase" = "bootstrap" ]; then
  darwin_user_key_file="@darwinUserKeyFile@"
  import_existing_user_key_on_bootstrap="@importExistingUserKeyOnBootstrap@"

  if [ ! -s "$key_file" ]; then
    install -d -m 700 "$key_dir"
    if [ "$import_existing_user_key_on_bootstrap" = "1" ] && [ "$darwin_user_key_file" != "$key_file" ] && [ -s "$darwin_user_key_file" ]; then
      cp "$darwin_user_key_file" "$key_file"
      chmod 600 "$key_file"
      echo "[sops-age-bootstrap] installed existing user age key into $key_file"
    else
      @ageBin@/bin/age-keygen -o "$key_file"
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

  if [ ! -s "$key_file" ] && [ "$nixos_import_from_host" = "1" ] && [ "$remote_fetch_enable" = "1" ]; then
    remote_host_raw="$(printenv "$remote_fetch_hostname_env_var" 2>/dev/null || true)"
    if [ -z "$remote_host_raw" ] && [ -r /mnt/lima-cidata/lima.env ]; then
      remote_host_raw="$(awk -F= '$1=="LIMA_HOSTNAME"{print $2}' /mnt/lima-cidata/lima.env | tail -n1)"
    fi

    if [ -n "$remote_host_raw" ]; then
      case "$remote_host_raw" in
        *.*) remote_host="$remote_host_raw" ;;
        *) remote_host="${remote_host_raw}${remote_fetch_mdns_suffix}" ;;
      esac

      tmp_key="$(mktemp)"
      chmod 600 "$tmp_key"

      if [ "$remote_fetch_use_sudo" = "1" ] && [ "$remote_fetch_user" != "root" ]; then
        remote_cmd="${sudo_bin} -n test -s '${remote_fetch_key_path}' && ${sudo_bin} -n cat '${remote_fetch_key_path}'"
      else
        remote_cmd="test -s '${remote_fetch_key_path}' && cat '${remote_fetch_key_path}'"
      fi

      if [ -n "$remote_fetch_user" ] && [ -x "$runuser_bin" ]; then
        if "$runuser_bin" -u "$remote_fetch_user" -- "$ssh_bin" -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "$remote_fetch_user@$remote_host" "$remote_cmd" > "$tmp_key" 2>/dev/null; then
          if [ -s "$tmp_key" ]; then
            install -d -m 700 "$key_dir"
            cp "$tmp_key" "$key_file"
            chmod 600 "$key_file"
            echo "[sops-age-bootstrap] imported host age key over ssh from $remote_fetch_user@$remote_host:$remote_fetch_key_path"
          fi
        fi
      elif "$ssh_bin" -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "$remote_host" "$remote_cmd" > "$tmp_key" 2>/dev/null; then
        if [ -s "$tmp_key" ]; then
          install -d -m 700 "$key_dir"
          cp "$tmp_key" "$key_file"
          chmod 600 "$key_file"
          echo "[sops-age-bootstrap] imported host age key over ssh from $remote_host:$remote_fetch_key_path"
        fi
      fi

      rm -f "$tmp_key"
    fi
  fi

  if [ ! -s "$key_file" ] && [ "$nixos_import_from_host" = "1" ]; then
    while IFS= read -r candidate; do
      [ -n "$candidate" ] || continue
      if [ -s "$candidate" ]; then
        install -d -m 700 "$key_dir"
        cp "$candidate" "$key_file"
        chmod 600 "$key_file"
        echo "[sops-age-bootstrap] imported host age key from $candidate into $key_file"
        break
      fi
    done <<'EOF'
@nixosHostKeyImportCandidates@
EOF
  fi

  if [ ! -s "$key_file" ]; then
    echo "[sops-age-bootstrap] ERROR: missing SOPS age key at $key_file"
    echo "[sops-age-bootstrap] either provision the key manually or run one activation with nxmatic.sopsAgeKeyBootstrap.phase=\"bootstrap\""
    exit 1
  fi
fi

if [ "$export_public_key_on_activation" = "1" ] && [ -s "$key_file" ]; then
  install -d -m 755 "$public_key_dir"
  @ageBin@/bin/age-keygen -y "$key_file" > "$public_key_file"
  chmod 644 "$public_key_file"
  echo "[sops-age-bootstrap] published host age recipient to $public_key_file"
fi