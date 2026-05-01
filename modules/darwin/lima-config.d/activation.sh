#!/usr/bin/env -S bash -euo pipefail
# shellcheck source=/dev/null
source @nixBashTrampoline@

main() {
  local ndh_nix_cli_args_raw="${NDH_NIX_CLI_ARGS:--L -v -v}"
  local -a ndh_nix_cli_args=()
  local gcroot_user=""
  local gcroot_group=""

  if [[ "$(id -u)" -eq 0 ]] && [[ -n "${SUDO_USER:-}" ]] && id -u "${SUDO_USER}" >/dev/null 2>&1; then
    gcroot_user="${SUDO_USER}"
  else
    gcroot_user="$(id -un)"
  fi

  if [[ -n "$gcroot_user" ]] && id -u "$gcroot_user" >/dev/null 2>&1; then
    gcroot_group="$(id -gn "$gcroot_user" 2>/dev/null || true)"
  fi

  if [[ -n "${ndh_nix_cli_args_raw}" ]]; then
    read -r -a ndh_nix_cli_args <<< "${ndh_nix_cli_args_raw}"
  fi

  relink_path() {
    local src="$1"
    local dst="$2"
    local label="$3"

    if [ -d "$dst" ] && [ ! -L "$dst" ]; then
      echo "[limaConfig][WARN] ${label} destination is a directory; removing to restore symlink semantics: $dst"
      rm -rf "$dst"
    fi

    rm -f "$dst"
    ln -s "$src" "$dst"

    if [ -L "$dst" ]; then
      if [[ "$dst" == "/nix/var/nix/gcroots/per-user/${gcroot_user}/"* ]] && [[ "$(id -u)" -eq 0 ]] && [[ -n "$gcroot_group" ]]; then
        chown -h "${gcroot_user}:${gcroot_group}" "$dst" 2>/dev/null || true
      fi
      echo "[limaConfig] ${label}: $dst -> $(readlink "$dst" || echo '<not-a-symlink>')"
      return 0
    fi

    echo "[limaConfig][ERROR] ${label} destination is not a symlink after update: $dst"
    return 1
  }

  resolve_manifest_image_candidate() {
    local manifest_dir="$1"
    local manifest_source_out="$2"
    local image_rel="$3"

    local candidate=""
    if [[ -n "$manifest_dir" && -f "$manifest_dir/$image_rel" ]]; then
      candidate="$manifest_dir/$image_rel"
    elif [[ -n "$manifest_source_out" && -f "$manifest_source_out/$image_rel" ]]; then
      candidate="$manifest_source_out/$image_rel"
    fi

    printf '%s\n' "$candidate"
  }

  lima_disk_import_if_available() {
    local disk_name="$1"
    local disk_image_path="$2"
    local runtime_lima_home="${effective_home}/.lima"
    local import_error=""

    limactl_as_runtime_user() {
      if [[ "$(id -u)" -eq 0 ]]; then
        if [[ -z "${gcroot_user}" ]]; then
          echo "[limaConfig][WARN] cannot run limactl as root without a runtime user"
          return 1
        fi
        sudo -u "${gcroot_user}" env HOME="${effective_home}" LIMA_HOME="${runtime_lima_home}" limactl "$@"
        return $?
      fi

      HOME="${effective_home}" LIMA_HOME="${runtime_lima_home}" limactl "$@"
    }

    if [[ -z "$disk_image_path" || ! -f "$disk_image_path" ]]; then
      echo "[limaConfig][INFO] skip disk import for $disk_name (image missing)"
      return 0
    fi

    if ! command -v limactl >/dev/null 2>&1; then
      echo "[limaConfig][WARN] limactl not found; cannot import disk $disk_name from $disk_image_path"
      return 0
    fi

    local in_use
    in_use=$(limactl_as_runtime_user disk list --json 2>/dev/null \
      | jq -r --arg name "$disk_name" 'select(.name == $name) | .instance // empty')
    if [[ -n "$in_use" ]]; then
      echo "[limaConfig][INFO] skip disk import for $disk_name (in use by VM: $in_use)"
      return 0
    fi

    limactl_as_runtime_user disk delete "$disk_name" >/dev/null 2>&1 || true
    if import_error="$(limactl_as_runtime_user disk import "$disk_name" "$disk_image_path" 2>&1 >/dev/null)"; then
      echo "[limaConfig] imported disk $disk_name from $disk_image_path"
      return 0
    fi

    if [[ -n "${import_error}" ]]; then
      echo "[limaConfig][WARN] failed to import disk $disk_name from $disk_image_path: ${import_error}"
    else
      echo "[limaConfig][WARN] failed to import disk $disk_name from $disk_image_path"
    fi
    return 0
  }

  materialize_lima_yaml_with_image_path() {
    local src="$1"
    local dst="$2"
    local image_path="$3"
    local configured_home_path="$4"
    local effective_home_path="$5"
    local label="$6"
    local tmp

    tmp="$(mktemp "${dst}.XXXXXX")"
    awk \
      -v newLocation="file://${image_path}" \
      -v configuredHome="${configured_home_path}" \
      -v effectiveHome="${effective_home_path}" '
      BEGIN { done = 0 }
      {
        if (!done && $0 ~ /^[[:space:]]*location:[[:space:]]*"?file:\/\//) {
          sub(/file:\/\/[^"[:space:]]+/, newLocation)
          done = 1
        }

        if (configuredHome != "" && effectiveHome != "" && configuredHome != effectiveHome) {
          if ($0 ~ /^[[:space:]]*-?[[:space:]]*location:[[:space:]]*"?\//) {
            if (match($0, /location:[[:space:]]*"?([^"[:space:]]+)/, m)) {
              oldPath = m[1]
              if (oldPath == configuredHome || index(oldPath, configuredHome "/") == 1) {
                newPath = effectiveHome substr(oldPath, length(configuredHome) + 1)
                sub(oldPath, newPath)
              }
            }
          }

          if ($0 ~ /^[[:space:]]*mountPoint:[[:space:]]*"?\//) {
            if (match($0, /mountPoint:[[:space:]]*"?([^"[:space:]]+)/, m)) {
              oldMount = m[1]
              if (oldMount == configuredHome || index(oldMount, configuredHome "/") == 1) {
                newMount = effectiveHome substr(oldMount, length(configuredHome) + 1)
                sub(oldMount, newMount)
              }
            }
          }
        }

        print
      }
    ' "$src" > "$tmp"

    mv "$tmp" "$dst"
    chmod 0644 "$dst"
    echo "[limaConfig] ${label}: $dst (image=file://${image_path})"
  }

  echo "[limaConfig] start $(date) host=@effectiveHostName@ user=@profileUser@"

  configured_home="@profileHome@"
  effective_home="$configured_home"
  runtime_user="$(id -un)"
  runtime_home="${HOME:-}"
  if [ ! -d "$effective_home" ]; then
    if [ -n "$runtime_home" ] && [ -d "$runtime_home" ]; then
      echo "[limaConfig][WARN] configured profile home missing: $configured_home; using HOME for runtime user $runtime_user: $runtime_home"
      effective_home="$runtime_home"
    else
      discovered_home="$(dscl . -read "/Users/${runtime_user}" NFSHomeDirectory 2>/dev/null | awk '{print $2}' || true)"
      if [ -n "$discovered_home" ] && [ -d "$discovered_home" ]; then
        echo "[limaConfig][WARN] configured profile home missing: $configured_home; using runtime home from dscl for $runtime_user: $discovered_home"
        effective_home="$discovered_home"
      else
        echo "[limaConfig][WARN] configured profile home missing and runtime home discovery failed; keeping configured path: $configured_home"
      fi
    fi
  fi

  : "Create Lima configuration directory in profile home"
  mkdir -p "${effective_home}/.lima/nerd-nixos"
  mkdir -p "${effective_home}/.lima/_config"

  : "Install managed host-side Lima wrapper as symlink to store path"
  relink_path "@limaRunScript@" "${effective_home}/.lima/run.sh" "run.sh installed"
  rm -f "${effective_home}/.lima/run.sh~"

  host_pub="@hostPublicKeyPath@"
  host_priv="@hostPrivateKeyPath@"

  if [[ "$host_pub" == "${configured_home}/"* ]] && [[ "$effective_home" != "$configured_home" ]]; then
    runtime_host_pub="${effective_home}${host_pub#"${configured_home}"}"
    echo "[limaConfig][WARN] rewriting host public key path for runtime home ${runtime_user}: $host_pub -> $runtime_host_pub"
    host_pub="$runtime_host_pub"
  fi

  if [[ "$host_priv" == "${configured_home}/"* ]] && [[ "$effective_home" != "$configured_home" ]]; then
    runtime_host_priv="${effective_home}${host_priv#"${configured_home}"}"
    echo "[limaConfig][WARN] rewriting host private key path for runtime home ${runtime_user}: $host_priv -> $runtime_host_priv"
    host_priv="$runtime_host_priv"
  fi

  : "Ensure canonical key target directories exist"
  mkdir -p "$(dirname "$host_pub")"
  mkdir -p "$(dirname "$host_priv")"

  : "Symlink Lima user key material from host-managed keys.d"
  ln -sf "$host_pub" "${effective_home}/.lima/_config/user.pub"
  ln -sf "$host_priv" "${effective_home}/.lima/_config/user"

  : "Resolve NixOS disk image and update GC-root link"
  img_manifest="@imageManifestPath@"
  img_store="@imageStorePath@"
  img_src="@imageSourcePath@"
  img_dst="@imageTargetPath@"
  image_flake_attr="@imageFlakeAttr@"
  image_flake_path="@nixosFlakePath@"

  if [[ "$img_dst" == "${configured_home}/"* ]] && [[ "$effective_home" != "$configured_home" ]]; then
    runtime_img_dst="${effective_home}${img_dst#"${configured_home}"}"
    echo "[limaConfig][WARN] rewriting image target for runtime home ${runtime_user}: $img_dst -> $runtime_img_dst"
    img_dst="$runtime_img_dst"
  fi

  # Canonical runtime policy: per-user gcroot follows the effective invoking user
  # (SUDO_USER when running as root via sudo, otherwise current user).
  if [[ "$img_dst" =~ ^/nix/var/nix/gcroots/per-user/([^/]+)/(.+)$ ]]; then
    img_dst_user="${BASH_REMATCH[1]}"
    img_dst_tail="${BASH_REMATCH[2]}"
    if [[ -n "$gcroot_user" && "$img_dst_user" != "$gcroot_user" ]]; then
      runtime_img_dst="/nix/var/nix/gcroots/per-user/${gcroot_user}/${img_dst_tail}"
      echo "[limaConfig][INFO] rewriting image target gcroot user: $img_dst -> $runtime_img_dst"
      img_dst="$runtime_img_dst"
    fi
  fi

  mkdir -p "$(dirname "$img_dst")"
  if [[ "$(id -u)" -eq 0 ]] && [[ -n "$gcroot_group" ]] && [[ "$img_dst" == "/nix/var/nix/gcroots/per-user/${gcroot_user}/"* ]]; then
    chown "${gcroot_user}:${gcroot_group}" "$(dirname "$img_dst")" 2>/dev/null || true
  fi
  resolved_ref="${image_flake_path}/hosts/@effectiveHostName@#${image_flake_attr}"
  resolved_out=""
  resolved_img=""
  manifest_img=""
  manifest_source_out=""
  selected_img=""
  selected_source=""

  if [ -n "$img_manifest" ] && [ -f "$img_manifest" ]; then
    manifest_dir="$(dirname "$img_manifest")"
    manifest_image_path="$(awk -F': *' '$1 == "imagePath" { print $2; exit }' "$img_manifest" | sed -e 's/^"//' -e 's/"$//')"
    manifest_source_out="$(awk -F': *' '$1 == "sourceOutPath" { print $2; exit }' "$img_manifest" | sed -e 's/^"//' -e 's/"$//')"

    if [ -n "$manifest_image_path" ]; then
      if [[ "$manifest_image_path" = /* ]]; then
        manifest_img="$manifest_image_path"
      else
        manifest_img="${manifest_dir}/${manifest_image_path}"
      fi

      if [ ! -f "$manifest_img" ] && [ -n "$manifest_source_out" ] && [ -f "${manifest_source_out}/${manifest_image_path}" ]; then
        manifest_img="${manifest_source_out}/${manifest_image_path}"
      fi
    fi
  fi

  if [ -n "$manifest_img" ] && [ -f "$manifest_img" ]; then
    echo "[limaConfig] resolved image via manifest: $img_manifest -> $manifest_img"
    selected_img="$manifest_img"
    selected_source="manifest"
  elif [ -n "$img_store" ] && [ -f "$img_store" ]; then
    echo "[limaConfig] using store-pinned image: $img_store"
    selected_img="$img_store"
    selected_source="store"
  elif [ -n "$img_src" ] && [ -f "$img_src" ]; then
    echo "[limaConfig][WARN] flake image resolution failed; using configured source fallback: $img_src"
    selected_img="$img_src"
    selected_source="source"
  else
    # Expensive fallback only when no local descriptor/store/source image is usable.
    if command -v nix >/dev/null 2>&1; then
      resolved_out="$(nix "${ndh_nix_cli_args[@]}" build "$resolved_ref" --no-link --print-out-paths 2>/dev/null | tail -n 1 || true)"
      if [ -n "$resolved_out" ] && [ -f "${resolved_out}/manifest.yaml" ]; then
        resolved_image_rel="$(awk -F': *' '$1 == "imagePath" { print $2; exit }' "${resolved_out}/manifest.yaml" | sed -e 's/^"//' -e 's/"$//')"
        if [ -n "$resolved_image_rel" ] && [ -f "${resolved_out}/${resolved_image_rel}" ]; then
          resolved_img="${resolved_out}/${resolved_image_rel}"
        fi
      fi

      if [ -z "$resolved_img" ] && [ -f "${resolved_out}/boot.img" ]; then
        resolved_img="${resolved_out}/boot.img"
      fi

      if [ -z "$resolved_img" ] && [ -f "${resolved_out}/nixos.img" ]; then
        resolved_img="${resolved_out}/nixos.img"
      fi

      if [ -z "$resolved_img" ] && [ -f "${resolved_out}/tank1.img" ]; then
        resolved_img="${resolved_out}/tank1.img"
      fi
    fi

    if [ -n "$resolved_out" ] && [ -f "$resolved_img" ]; then
      echo "[limaConfig] resolved image via $resolved_ref -> $resolved_img"
      selected_img="$resolved_img"
      selected_source="flake"
    fi
  fi

  if [ -z "$selected_img" ] && { [ -L "$img_dst" ] || [ -f "$img_dst" ]; }; then
    echo "[limaConfig][INFO] keeping existing image target at $img_dst"
  elif [ -z "$selected_img" ]; then
    echo "[limaConfig][ERROR] unable to resolve disk image (manifest=$img_manifest, store=$img_store, ref=$resolved_ref, source=$img_src)"
  fi

  if [ -n "$selected_img" ] && [ -f "$selected_img" ]; then
    img_dst_parent="$(dirname "$img_dst")"
    if [ ! -d "$img_dst_parent" ]; then
      mkdir -p "$img_dst_parent" 2>/dev/null || true
    fi

    if [ ! -d "$img_dst_parent" ]; then
      echo "[limaConfig][ERROR] image target parent directory missing: $img_dst_parent"
      echo "[limaConfig][HINT] create it manually, then rerun activation: mkdir -p '$img_dst_parent'"
      exit 1
    fi

    relink_path "$selected_img" "$img_dst" "updated image target ($selected_source)"
  fi

  # When using bringup ZFS artifact sets, import canonical external pool disks.
  # boot.img is the Lima primary image (EFI boot, vda). tank1/2/3/recover are
  # all additional disks (vdb/vdc/vdd/vde) forming the ZFS raidz1 pool.
  if [ -n "$img_manifest" ] && [ -f "$img_manifest" ]; then
    manifest_dir="$(dirname "$img_manifest")"
    tank1_img="$(resolve_manifest_image_candidate "$manifest_dir" "$manifest_source_out" "tank1.img")"
    tank2_img="$(resolve_manifest_image_candidate "$manifest_dir" "$manifest_source_out" "tank2.img")"
    tank3_img="$(resolve_manifest_image_candidate "$manifest_dir" "$manifest_source_out" "tank3.img")"

    lima_disk_import_if_available "nerd-nixos-tank1" "$tank1_img"
    lima_disk_import_if_available "nerd-nixos-tank2" "$tank2_img"
    lima_disk_import_if_available "nerd-nixos-tank3" "$tank3_img"
  fi

  : "Install managed Lima config"
  lima_dir="${effective_home}/.lima/nerd-nixos"
  lima_runtime_dir="${lima_dir}/.generated"
  lima_runtime="${lima_runtime_dir}/lima.yaml"
  lima_active="${lima_dir}/lima.yaml"

  mkdir -p "$lima_runtime_dir"
  materialize_lima_yaml_with_image_path "@limaConfigYaml@" "$lima_runtime" "$img_dst" "$configured_home" "$effective_home" "runtime config"

  relink_path "$lima_runtime" "$lima_active" "active lima config link"

  # Defensive repair path for filesystems/environments where symlink checks can
  # behave unexpectedly during activation (keep non-fatal).
  if [ ! -e "$lima_active" ] && [ ! -L "$lima_active" ]; then
    ln -sfn "$lima_runtime" "$lima_active" 2>/dev/null || true
  fi

  if [ ! -e "$lima_active" ] && [ ! -L "$lima_active" ]; then
    cp -f "$lima_runtime" "$lima_active" 2>/dev/null || true
  fi

  : "Verify output file"
  if [ -e "$lima_active" ] || [ -L "$lima_active" ]; then
    echo "[limaConfig] active lima config: $lima_active -> $(readlink "$lima_active" || echo '<regular-file>')"
    echo "[limaConfig] config size=$(wc -c < "@limaConfigYaml@")"
    grep -E 'gateway|clusterId|display' "@limaConfigYaml@" || true
    user_marker_dir="${effective_home}/.local/var/db"
    user_marker_path="${user_marker_dir}/lima-config-generated"
    mkdir -p "$user_marker_dir"
    touch "$user_marker_path"
    echo "[limaConfig] wrote user marker: $user_marker_path"

    if [ -w /var/db ]; then
      touch /var/db/lima-config-generated
      echo "[limaConfig] wrote system marker: /var/db/lima-config-generated"
    else
      echo "[limaConfig][INFO] skipping system marker /var/db/lima-config-generated (insufficient privileges)"
    fi
  else
    echo "[limaConfig][WARN] lima.yaml missing after generation attempt: $lima_active"
  fi
  echo "[limaConfig] end $(date)"
}

ndh::logger:command:run darwin.activationScripts.postActivation.lima-config main "$@"
