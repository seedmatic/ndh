#!/usr/bin/env -S bash -euo pipefail
source @logger@

main() {
  local ndh_nix_cli_args_raw="${NDH_NIX_CLI_ARGS:--L -v -v}"
  local -a ndh_nix_cli_args=()

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
      echo "[limaConfig] ${label}: $dst -> $(readlink "$dst" || echo '<not-a-symlink>')"
      return 0
    fi

    echo "[limaConfig][ERROR] ${label} destination is not a symlink after update: $dst"
    return 1
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

  : "Ensure canonical key target directories exist"
  mkdir -p "$(dirname "$host_pub")"
  mkdir -p "$(dirname "$host_priv")"

  : "Symlink Lima user key material from host-managed keys.d"
  ln -sf "$host_pub" "${effective_home}/.lima/_config/user.pub"
  ln -sf "$host_priv" "${effective_home}/.lima/_config/user"

  : "Resolve NixOS disk image and update GC-root link"
  img_descriptor="@imageDescriptorPath@"
  img_store="@imageStorePath@"
  img_src="@imageSourcePath@"
  img_dst="@imageTargetPath@"
  image_flake_attr="@imageFlakeAttr@"
  image_flake_path="@nixosFlakePath@"

  if [[ "$img_dst" == "${configured_home}/"* ]] && [[ "$effective_home" != "$configured_home" ]]; then
    runtime_img_dst="${effective_home}${img_dst#${configured_home}}"
    echo "[limaConfig][WARN] rewriting image target for runtime home ${runtime_user}: $img_dst -> $runtime_img_dst"
    img_dst="$runtime_img_dst"
  fi

  # When this script is executed from Home Manager activation, runtime user can
  # differ from the system profile user baked at package build-time. Keep one
  # canonical gcroot target for the runtime user to avoid stale user-scoped links.
  if [[ "$img_dst" =~ ^/nix/var/nix/gcroots/per-user/([^/]+)/(.+)$ ]]; then
    img_dst_user="${BASH_REMATCH[1]}"
    img_dst_tail="${BASH_REMATCH[2]}"
    if [[ -n "$runtime_user" && "$img_dst_user" != "$runtime_user" ]]; then
      runtime_user_img_dst="/nix/var/nix/gcroots/per-user/${runtime_user}/${img_dst_tail}"
      echo "[limaConfig][WARN] rewriting image target for runtime user ${runtime_user}: $img_dst -> $runtime_user_img_dst"
      img_dst="$runtime_user_img_dst"
    fi
  fi

  mkdir -p "$(dirname "$img_dst")"
  resolved_ref="${image_flake_path}/hosts/@effectiveHostName@#${image_flake_attr}"
  resolved_out=""
  resolved_img=""
  descriptor_img=""
  selected_img=""
  selected_source=""

  if [ -n "$img_descriptor" ] && [ -f "$img_descriptor" ]; then
    descriptor_dir="$(dirname "$img_descriptor")"
    descriptor_image_path="$(awk -F': *' '$1 == "imagePath" { print $2; exit }' "$img_descriptor" | sed -e 's/^"//' -e 's/"$//')"
    descriptor_source_out="$(awk -F': *' '$1 == "sourceOutPath" { print $2; exit }' "$img_descriptor" | sed -e 's/^"//' -e 's/"$//')"

    if [ -n "$descriptor_image_path" ]; then
      if [[ "$descriptor_image_path" = /* ]]; then
        descriptor_img="$descriptor_image_path"
      else
        descriptor_img="${descriptor_dir}/${descriptor_image_path}"
      fi

      if [ ! -f "$descriptor_img" ] && [ -n "$descriptor_source_out" ] && [ -f "${descriptor_source_out}/${descriptor_image_path}" ]; then
        descriptor_img="${descriptor_source_out}/${descriptor_image_path}"
      fi
    fi
  fi

  if [ -n "$descriptor_img" ] && [ -f "$descriptor_img" ]; then
    echo "[limaConfig] resolved image via descriptor: $img_descriptor -> $descriptor_img"
    selected_img="$descriptor_img"
    selected_source="descriptor"
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
      resolved_img="${resolved_out}/nixos.img"
    fi

    if [ -n "$resolved_out" ] && [ -f "$resolved_img" ]; then
      echo "[limaConfig] resolved image via $resolved_ref -> $resolved_img"
      selected_img="$resolved_img"
      selected_source="flake"
    fi
  fi

  if [ -z "$selected_img" ] && ([ -L "$img_dst" ] || [ -f "$img_dst" ]); then
    echo "[limaConfig][INFO] keeping existing image target at $img_dst"
  elif [ -z "$selected_img" ]; then
    echo "[limaConfig][ERROR] unable to resolve disk image (descriptor=$img_descriptor, store=$img_store, ref=$resolved_ref, source=$img_src)"
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

  : "Install managed Lima config variants (headless + gui)"
  lima_dir="${effective_home}/.lima/nerd-nixos"
  lima_headless_link="${lima_dir}/lima.headless.yaml"
  lima_gui_link="${lima_dir}/lima.gui.yaml"
  lima_active="${lima_dir}/lima.yaml"

  relink_path "@limaConfigYamlHeadless@" "$lima_headless_link" "headless config link"
  relink_path "@limaConfigYamlGui@" "$lima_gui_link" "gui config link"

  : "Keep active lima.yaml on headless profile by default"
  relink_path "$lima_headless_link" "$lima_active" "active lima config link"

  # Defensive repair path for filesystems/environments where symlink checks can
  # behave unexpectedly during activation (keep non-fatal).
  if [ ! -e "$lima_active" ] && [ ! -L "$lima_active" ]; then
    ln -sfn "@limaConfigYamlHeadless@" "$lima_active" 2>/dev/null || true
  fi

  if [ ! -e "$lima_active" ] && [ ! -L "$lima_active" ]; then
    cp -f "@limaConfigYamlHeadless@" "$lima_active" 2>/dev/null || true
  fi

  : "Verify output file"
  if [ -e "$lima_active" ] || [ -L "$lima_active" ]; then
    echo "[limaConfig] active lima config: $lima_active -> $(readlink "$lima_active" || echo '<regular-file>')"
    echo "[limaConfig] headless size=$(wc -c < "@limaConfigYamlHeadless@")"
    echo "[limaConfig] gui size=$(wc -c < "@limaConfigYamlGui@")"
    grep -E 'gateway|clusterId|display' "@limaConfigYamlHeadless@" || true
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
