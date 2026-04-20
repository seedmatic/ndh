#!/usr/bin/env -S bash -euo pipefail
# shellcheck source=/dev/null
source @bashTrampoline@
# shellcheck source=/dev/null
source @logger@

main() {
	set -euo pipefail

	local ndh_nix_cli_args_raw="${NDH_NIX_CLI_ARGS:--L -v -v}"
	local ndh_tart_factory_reset_raw="${NDH_TART_FACTORY_RESET:-0}"
	local -a ndh_nix_cli_args=()
	local profile_user="@profileUser@"
	local profile_group=""
	local factory_reset=0

	if id -u "$profile_user" >/dev/null 2>&1; then
		profile_group="$(id -gn "$profile_user" 2>/dev/null || true)"
	fi

	if [[ -n "${ndh_nix_cli_args_raw}" ]]; then
		read -r -a ndh_nix_cli_args <<<"${ndh_nix_cli_args_raw}"
	fi

	tart:bool:is-true() {
		local value="${1:-}"
		value="${value,,}"
		[[ "$value" == "1" || "$value" == "true" || "$value" == "yes" || "$value" == "on" ]]
	}

	if tart:bool:is-true "$ndh_tart_factory_reset_raw"; then
		factory_reset=1
	fi

	tart:fs:path:relink() {
		local src="$1"
		local dst="$2"
		local label="$3"

		if [ -d "$dst" ] && [ ! -L "$dst" ]; then
			: "[tartConfig][WARN] ${label} destination is a directory; removing to restore symlink semantics: $dst"
			rm -rf "$dst"
		fi

		rm -f "$dst"
		ln -s "$src" "$dst"

		if [ -L "$dst" ]; then
			if [[ "$dst" == "/nix/var/nix/gcroots/per-user/${profile_user}/"* ]] && [[ "$(id -u)" -eq 0 ]] && [[ -n "$profile_group" ]]; then
				chown -h "${profile_user}:${profile_group}" "$dst" 2>/dev/null || true
			fi
			: "${label}: $dst -> $(readlink "$dst" || echo '<not-a-symlink>')"
			return 0
		fi

		: "[tartConfig][ERROR] ${label} destination is not a symlink after update: $dst"
		return 1
	}

	tart:fs:dir:ensure() {
		local dir="$1"
		local mode="${2:-0755}"

		if [[ "$(id -u)" -eq 0 ]] && [[ -n "$profile_group" ]] && [[ "$dir" == "/nix/var/nix/gcroots/per-user/${profile_user}"* ]]; then
			install -d -m "$mode" -o "$profile_user" -g "$profile_group" "$dir"
		else
			install -d -m "$mode" "$dir"
		fi
	}

	tart:runtime:home:resolve() {
		configured_home="@profileHome@"
		effective_home="$configured_home"
		runtime_user="$(id -un)"
		runtime_home="${HOME:-}"

		if [ ! -d "$effective_home" ]; then
			if [ -n "$runtime_home" ] && [ -d "$runtime_home" ]; then
				: "[tartConfig][WARN] configured profile home missing: $configured_home; using HOME for runtime user $runtime_user: $runtime_home"
				effective_home="$runtime_home"
			else
				discovered_home="$(
					dscl . -read "/Users/${runtime_user}" NFSHomeDirectory -plist 2>/dev/null |
						yq -p=xml -r '.plist.dict.array.string // ""' 2>/dev/null ||
						true
				)"
				if [ -n "$discovered_home" ] && [ -d "$discovered_home" ]; then
					: "[tartConfig][WARN] configured profile home missing: $configured_home; using runtime home from dscl for $runtime_user: $discovered_home"
					effective_home="$discovered_home"
				else
					: "[tartConfig][WARN] configured profile home missing and runtime home discovery failed; keeping configured path: $configured_home"
				fi
			fi
		fi
	}

	tart:runtime:tooling:validate() {
		tart_bin=""
		if [ -n "$tart_binary_hint" ]; then
			tart_bin="$tart_binary_hint"
		fi

		if [ -z "$tart_bin" ] || [ ! -x "$tart_bin" ]; then
			: "[tartConfig][ERROR] tart CLI is not executable at configured path; cannot materialize VM"
			: "[tartConfig][ERROR] tartBinaryPath hint=$tart_binary_hint"
			exit 1
		fi

		if [ ! -x "$nix_bin" ]; then
			: "[tartConfig][ERROR] nix CLI is not executable at configured path: $nix_bin"
			exit 1
		fi

		if [ ! -x "$diskutil_bin" ]; then
			: "[tartConfig][ERROR] diskutil is not executable at configured path: $diskutil_bin"
			exit 1
		fi

		if [ ! -x "$truncate_bin" ]; then
			: "[tartConfig][ERROR] truncate is not executable at configured path: $truncate_bin"
			exit 1
		fi

		if ! command -v yq >/dev/null 2>&1; then
			: "[tartConfig][ERROR] yq is not available in PATH; cannot patch tart config JSON"
			exit 1
		fi
	}

	tart:runtime:path:setup() {
		tart_env_path="$(dirname "$diskutil_bin"):$(dirname "$hdiutil_bin"):/usr/bin:/bin:/usr/sbin:/sbin"
	}

	tart:diskutil:run() {
		PATH="$tart_env_path" "$diskutil_bin" "$@" 1>&2
	}

	: "start $(date) host=@effectiveHostName@ user=@profileUser@"

	tart:runtime:home:resolve

	raw_manifest="@rawImageManifestPath@"
	raw_store="@rawImageStorePath@"
	raw_source="@rawImageSourcePath@"
	raw_target="@rawImageTargetPath@"
	asif_target="@asifImageTargetPath@"
	vm_name="@vmName@"
	vm_disk_format="@vmDiskFormat@"
	vm_disk_size_gib="@vmDiskSizeGiB@"
	vm_cpu_count="@vmCpuCount@"
	vm_memory_mib="@vmMemoryMiB@"
	vm_display_width="@vmDisplayWidth@"
	vm_display_height="@vmDisplayHeight@"
	vm_mac_address="@vmMacAddress@"
	vm_data_disk_size_gib="@vmDataDiskSizeGiB@"
	tart_binary_hint="@tartBinaryPath@"
	nix_bin="@nixBinaryPath@"
	diskutil_bin="@diskutilBinaryPath@"
	hdiutil_bin="@hdiutilBinaryPath@"
	truncate_bin="@truncateBinaryPath@"
	tart_run_script_store="@tartRunScript@"
	image_flake_attr="@imageFlakeAttr@"
	image_flake_path="@nixosFlakePath@"

	tart:runtime:tooling:validate
	tart:runtime:path:setup

	tart:vm:run() {
		PATH="$tart_env_path" "$tart_bin" "$@"
	}

	tart:vm:exists() {
		local vm="$1"
		local listed_vm
		while read -r listed_vm _; do
			if [[ "$listed_vm" == "$vm" ]]; then
				return 0
			fi
		done < <(tart:vm:run list 2>/dev/null)
		return 1
	}

	tart:vm:ensure() {
		local vm="$1"
		local disk_size="$2"
		local disk_format="$3"

		if tart:vm:exists "$vm"; then
			: "tart VM already exists: $vm"
		else
			: "creating tart VM: $vm (os=linux disk-size=${disk_size}GiB disk-format=${disk_format})"
			tart:vm:run create "$vm" --linux --disk-size "$disk_size" --disk-format "$disk_format"
		fi
	}
	tart_vm_dir="${effective_home}/.tart/vms/${vm_name}"
	tart_vm_disk="${tart_vm_dir}/disk.img"
	tart_vm_config="${tart_vm_dir}/config.json"
	tart_vm_run_wrapper="${effective_home}/.tart/vms/${vm_name}.sh"
	tart_data_disk_dir="${effective_home}/.tart/disks/${vm_name}"
	tart_data_disks=(
		"${tart_data_disk_dir}/tank1.asif"
		"${tart_data_disk_dir}/tank2.asif"
		"${tart_data_disk_dir}/tank3.asif"
		"${tart_data_disk_dir}/recover.asif"
	)

	tart:vm:data-disk:create-asif() {
		local disk="$1"
		local size_gib="$2"
		local bootstrap_raw="${3:-}"
		local bootstrap_size_gib=1
		local initial_size_gib="$bootstrap_size_gib"
		local tmp_raw
		local own_tmp_raw=0

		if [ -n "$bootstrap_raw" ]; then
			tmp_raw="$bootstrap_raw"
		else
			tmp_raw="$(mktemp "${disk}.raw.XXXXXX")"
			own_tmp_raw=1
			cleanup_tmp_raw() {
				trap - RETURN
				rm -f "$tmp_raw" 2>/dev/null || true
			}
			trap cleanup_tmp_raw RETURN

			rm -f "$tmp_raw"
		fi

		if [[ "$size_gib" =~ ^[0-9]+$ ]] && ((size_gib < bootstrap_size_gib)); then
			initial_size_gib="$size_gib"
		fi

		if ((own_tmp_raw == 1)); then
			: "creating data disk bootstrap image: $disk (${initial_size_gib}GiB raw -> ASIF, then resize to ${size_gib}GiB)"
			"$truncate_bin" -s "${initial_size_gib}g" "$tmp_raw"
		else
			: "using shared bootstrap raw image for data disk creation: $disk"
		fi
		tart:diskutil:run image create from --format ASIF "$tmp_raw" "$disk"

		if [[ "$size_gib" =~ ^[0-9]+$ ]] && ((size_gib > initial_size_gib)); then
			: "resizing data disk ASIF to target size: $disk (${size_gib}GiB)"
			if ! tart:diskutil:run image resize --size "${size_gib}g" "$disk"; then
				: "[tartConfig][ERROR] failed to resize ASIF data disk to ${size_gib}GiB: $disk"
				exit 1
			fi
		fi

		if ((own_tmp_raw == 1)); then
			cleanup_tmp_raw
			trap - RETURN
		fi

		if [ ! -f "$disk" ]; then
			: "[tartConfig][ERROR] failed to create ASIF data disk: $disk"
			exit 1
		fi

		chmod 0644 "$disk" 2>/dev/null || true
		if [[ "$(id -u)" -eq 0 ]] && [[ -n "$profile_group" ]] && [[ "$disk" == "${effective_home}/"* ]]; then
			chown "${profile_user}:${profile_group}" "$disk" 2>/dev/null || true
		fi
	}

	tart:image:targets:normalize() {
		if [[ "$raw_target" == "${configured_home}/"* ]] && [[ "$effective_home" != "$configured_home" ]]; then
			runtime_raw_target="${effective_home}${raw_target#"${configured_home}"}"
			: "[tartConfig][WARN] rewriting raw target for runtime home ${runtime_user}: $raw_target -> $runtime_raw_target"
			raw_target="$runtime_raw_target"
		fi

		if [[ "$asif_target" == "${configured_home}/"* ]] && [[ "$effective_home" != "$configured_home" ]]; then
			runtime_asif_target="${effective_home}${asif_target#"${configured_home}"}"
			: "[tartConfig][WARN] rewriting asif target for runtime home ${runtime_user}: $asif_target -> $runtime_asif_target"
			asif_target="$runtime_asif_target"
		fi

		if [[ "$raw_target" =~ ^/nix/var/nix/gcroots/per-user/([^/]+)/(.+)$ ]]; then
			raw_target_user="${BASH_REMATCH[1]}"
			if [[ -n "$runtime_user" && "$raw_target_user" != "$runtime_user" ]]; then
				: "[tartConfig][INFO] keeping configured raw target user ${raw_target_user} (runtime user is ${runtime_user})"
			fi
		fi

		if [[ "$asif_target" =~ ^/nix/var/nix/gcroots/per-user/([^/]+)/(.+)$ ]]; then
			asif_target_user="${BASH_REMATCH[1]}"
			if [[ -n "$runtime_user" && "$asif_target_user" != "$runtime_user" ]]; then
				: "[tartConfig][INFO] keeping configured asif target user ${asif_target_user} (runtime user is ${runtime_user})"
			fi
		fi
	}

	tart:image:targets:ensure-gcroot() {
		tart:fs:dir:ensure "$(dirname "$asif_target")" 0755

		if [[ "$(id -u)" -eq 0 ]] && [[ -n "$profile_group" ]]; then
			if [[ "$asif_target" == "/nix/var/nix/gcroots/per-user/${profile_user}/"* ]]; then
				chown "${profile_user}:${profile_group}" "$(dirname "$asif_target")" 2>/dev/null || true
			fi
		fi
	}

	tart:vm:data-disks:ensure() {
		local shared_bootstrap_raw=""
		local shared_bootstrap_size_gib=1
		cleanup_shared_bootstrap_raw() {
			trap - RETURN
			if [ -n "$shared_bootstrap_raw" ]; then
				rm -f "$shared_bootstrap_raw" 2>/dev/null || true
			fi
		}

		tart:fs:dir:ensure "$tart_data_disk_dir" 0755
		trap cleanup_shared_bootstrap_raw RETURN
		for disk in "${tart_data_disks[@]}"; do
			if [ ! -f "$disk" ]; then
				if [ -z "$shared_bootstrap_raw" ] && [[ "$vm_data_disk_size_gib" =~ ^[0-9]+$ ]] && ((vm_data_disk_size_gib >= shared_bootstrap_size_gib)); then
					shared_bootstrap_raw="$(mktemp "${tart_data_disk_dir}/.bootstrap.raw.XXXXXX")"
					rm -f "$shared_bootstrap_raw"
					"$truncate_bin" -s "${shared_bootstrap_size_gib}g" "$shared_bootstrap_raw"
					: "prepared shared bootstrap raw image for data disks: $shared_bootstrap_raw (${shared_bootstrap_size_gib}GiB)"
				fi

				: "creating missing data disk during activation: $disk (${vm_data_disk_size_gib}GiB, ASIF)"
				tart:vm:data-disk:create-asif "$disk" "$vm_data_disk_size_gib" "$shared_bootstrap_raw"
			fi
		done
		cleanup_shared_bootstrap_raw
		trap - RETURN
	}

	tart:vm:factory-reset:apply() {
		if ((factory_reset == 0)); then
			return 0
		fi

		: "[tartConfig][WARN] factory reset requested (NDH_TART_FACTORY_RESET=${ndh_tart_factory_reset_raw})"
		: "[tartConfig][WARN] removing existing Tart root/data images before rematerialization"

		tart:vm:run stop "$vm_name" >/dev/null 2>&1 || true

		rm -f "$tart_vm_disk" 2>/dev/null || true
		rm -f "$asif_target" 2>/dev/null || true
		rm -f "$raw_target" 2>/dev/null || true

		for disk in "${tart_data_disks[@]}"; do
			rm -f "$disk" 2>/dev/null || true
		done

		: "[tartConfig][INFO] factory reset cleanup completed for vm=$vm_name"
	}

	tart:image:raw:resolve() {
		resolved_ref="${image_flake_path}/hosts/@effectiveHostName@#${image_flake_attr}"
		selected_raw=""
		selected_source=""
		manifest_img=""
		manifest_image_path=""
		manifest_source_out=""

		if [ -n "$raw_manifest" ] && [ -f "$raw_manifest" ]; then
			manifest_dir="$(dirname "$raw_manifest")"
			# shellcheck disable=SC1090
			source <(
				yq -p=yaml -o=shell '
          {
            manifest_image_path: (.imagePath // ""),
            manifest_source_out: (.sourceOutPath // "")
          }
        ' "$raw_manifest" 2>/dev/null || true
			)

			if [ -n "${manifest_image_path:-}" ]; then
				if [[ "$manifest_image_path" = /* ]]; then
					manifest_img="$manifest_image_path"
				else
					manifest_img="${manifest_dir}/${manifest_image_path}"
				fi

				if [ ! -f "$manifest_img" ] && [ -n "${manifest_source_out:-}" ] && [ -f "${manifest_source_out}/${manifest_image_path}" ]; then
					manifest_img="${manifest_source_out}/${manifest_image_path}"
				fi
			fi
		fi

		if [ -n "$manifest_img" ] && [ -f "$manifest_img" ]; then
			: "resolved raw image via manifest: $raw_manifest -> $manifest_img"
			selected_raw="$manifest_img"
			selected_source="manifest"
		elif [ -n "$raw_store" ] && [ -f "$raw_store" ]; then
			: "using store-pinned raw image: $raw_store"
			selected_raw="$raw_store"
			selected_source="store"
		elif [ -n "$raw_source" ] && [ -f "$raw_source" ]; then
			: "[tartConfig][WARN] flake image resolution failed; using configured source fallback: $raw_source"
			selected_raw="$raw_source"
			selected_source="source"
		elif [ -x "$nix_bin" ]; then
			resolved_out="$($nix_bin "${ndh_nix_cli_args[@]}" build "$resolved_ref" --no-link --json 2>/dev/null | yq -p=json -r '.[0].outputs.out // ""' 2>/dev/null || true)"
			resolved_img="${resolved_out}/nixos.img"
			if [ -n "$resolved_out" ] && [ -f "$resolved_img" ]; then
				: "resolved raw image via $resolved_ref -> $resolved_img"
				selected_raw="$resolved_img"
				selected_source="flake"
			fi
		fi

		if [ -z "$selected_raw" ] && { [ -L "$raw_target" ] || [ -f "$raw_target" ]; }; then
			: "[tartConfig][INFO] using existing raw image fallback target at $raw_target"
			selected_raw="$raw_target"
			selected_source="existing-target"
		elif [ -z "$selected_raw" ]; then
			: "[tartConfig][ERROR] unable to resolve raw disk image (manifest=$raw_manifest, store=$raw_store, ref=$resolved_ref, source=$raw_source)"
			exit 1
		fi

		if [ -n "$selected_raw" ] && [ -f "$selected_raw" ]; then
			if [[ "$raw_target" == "/nix/var/nix/gcroots/per-user/"* ]] && { [ -L "$raw_target" ] || [ -f "$raw_target" ]; }; then
				rm -f "$raw_target"
				: "removed stale raw gcroot target: $raw_target"
			fi
			: "using raw conversion source ($selected_source): $selected_raw"
		fi
	}

	tart:vm:root-disk:materialize-from-raw() {
		tart:vm:ensure "$vm_name" "$vm_disk_size_gib" "$vm_disk_format"
		tart:vm:run stop "$vm_name" >/dev/null 2>&1 || true

		if [ ! -d "$tart_vm_dir" ]; then
			: "[tartConfig][ERROR] tart VM directory missing after ensure/create: $tart_vm_dir"
			exit 1
		fi

		working_asif="$tart_vm_disk"
		rm -f "$working_asif"

		: "converting raw -> ASIF with diskutil image create (single-file mode, bin=$diskutil_bin, output=$working_asif)"
		tart:diskutil:run image create from --format ASIF "$selected_raw" "$working_asif"

		asif_output=""
		for candidate in "$working_asif" "${working_asif}.asif" "${working_asif}.dmg"; do
			if [ -f "$candidate" ]; then
				asif_output="$candidate"
				break
			fi
		done

		if [ -z "$asif_output" ]; then
			: "[tartConfig][ERROR] diskutil did not produce an ASIF output file for target: $working_asif"
			ls -la "$(dirname "$working_asif")" 2>/dev/null || true
			exit 1
		fi

		if [ "$asif_output" != "$working_asif" ]; then
			mv -f "$asif_output" "$working_asif"
		fi

		asif_output="$working_asif"

		chmod 0644 "$asif_output" 2>/dev/null || true
		if [[ "$(id -u)" -eq 0 ]] && [[ -n "$profile_group" ]] && [[ "$asif_output" == "${effective_home}/"* ]]; then
			chown "${profile_user}:${profile_group}" "$asif_output" 2>/dev/null || true
		fi

		if [ ! -e "$asif_output" ]; then
			: "[tartConfig][ERROR] ASIF output missing after diskutil conversion: $asif_output"
			exit 1
		fi
	}

	tart:vm:root-disk:resize() {
		if [[ -n "$vm_disk_size_gib" ]]; then
			local target_disk_bytes current_disk_bytes
			target_disk_size="${vm_disk_size_gib}g"
			target_disk_bytes="$((vm_disk_size_gib * 1024 * 1024 * 1024))"

			current_disk_bytes="$(
				"$diskutil_bin" image info --plist "$asif_output" 2>/dev/null |
					yq -p=xml -r --from-file=<(
cat <<'EOF'
.plist.dict.dict[]
| ((.key | [.] | flatten | to_entries | map(select(.value == "Total Bytes").key))[0]) as $idx
| select($idx != null)
| ((.integer // .string // "" | [.] | flatten)[$idx] // "")
EOF
					)
				)" 2>/dev/null || true					

			if [[ -n "$current_disk_bytes" ]] && [[ "$current_disk_bytes" =~ ^[0-9]+$ ]] && ((current_disk_bytes >= target_disk_bytes)); then
				: "root ASIF already at or above target size (${current_disk_bytes}B >= ${target_disk_bytes}B); skipping resize"
				return 0
			fi

			: "resizing ASIF root image to ${target_disk_size}: ${asif_output}"
			if ! tart:diskutil:run image resize --size "$target_disk_size" "$asif_output"; then
				: "[tartConfig][ERROR] failed to resize ASIF image with diskutil to ${target_disk_size}: ${asif_output}"
				exit 1
			fi
		fi
	}

	tart:vm:root-disk:publish-asif() {
		tart:fs:path:relink "$asif_output" "$asif_target" "updated ASIF image target"

		if [ ! -f "$tart_vm_disk" ]; then
			: "[tartConfig][ERROR] tart VM disk missing: $tart_vm_disk"
			exit 1
		fi
	}

	tart:vm:config:patch() {
		if [ -f "$tart_vm_config" ]; then
			VM_DISK_FORMAT="$vm_disk_format" \
				VM_DISPLAY_WIDTH="$vm_display_width" \
				VM_DISPLAY_HEIGHT="$vm_display_height" \
				VM_MAC_ADDRESS="$vm_mac_address" \
				yq -o=json -I=2 -i '.diskFormat = strenv(VM_DISK_FORMAT) |
                           .display = (.display // {}) |
                           .display.width = (strenv(VM_DISPLAY_WIDTH) | tonumber) |
                           .display.height = (strenv(VM_DISPLAY_HEIGHT) | tonumber) |
                           .macAddress = strenv(VM_MAC_ADDRESS)' "$tart_vm_config"
		fi
	}

	tart:vm:finalize() {
		chmod 0644 "$tart_vm_disk" 2>/dev/null || true
		if [[ "$(id -u)" -eq 0 ]] && [[ -n "$profile_group" ]] && [[ "$tart_vm_disk" == "${effective_home}/"* ]]; then
			chown "${profile_user}:${profile_group}" "$tart_vm_disk" 2>/dev/null || true
		fi

		tart:vm:run set "$vm_name" --cpu "$vm_cpu_count" --memory "$vm_memory_mib"
		tart:fs:path:relink "$tart_run_script_store" "$tart_vm_run_wrapper" "tart run wrapper link"
	}

	tart:image:targets:normalize
	tart:vm:factory-reset:apply
	tart:image:targets:ensure-gcroot
	tart:vm:data-disks:ensure
	tart:image:raw:resolve
	tart:vm:root-disk:materialize-from-raw
	tart:vm:root-disk:resize
	tart:vm:root-disk:publish-asif
	tart:vm:config:patch
	tart:vm:finalize

	: "tart VM materialized vm=$vm_name diskFormat=$vm_disk_format mac=$vm_mac_address cpu=$vm_cpu_count memoryMiB=$vm_memory_mib"
	: "tart run wrapper installed: $tart_vm_run_wrapper"

	: "done rawSource=$selected_raw asif=$asif_target"
	: "end $(date)"
}

ndh::logger:command:run "darwin.activationScripts.postActivation.tart-config.@vmName@" main "$@"
