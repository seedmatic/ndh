#!/usr/bin/env -S bash -euxo pipefail
# shellcheck disable=SC1091
source "@nixBashTrampoline@"

manifest_path="@manifestPath@"
activation_script_store="@tartActivationScript@"
extra_run_args_raw="${RUN_EXTRA_ARGS:-}"

tart:manifest:load() {
	if [[ ! -r "$manifest_path" ]]; then
		echo "[ERROR] run manifest missing/unreadable: ${manifest_path}" >&2
		exit 1
	fi

	if ! command -v yq >/dev/null 2>&1; then
		echo "[ERROR] yq is required to parse run manifest: ${manifest_path}" >&2
		exit 1
	fi

	# shellcheck source=/dev/null
	source <(yq -p=yaml -o=shell '.' "$manifest_path")
}

tart:runtime:configure() {
	vm_disk_dir="${HOME}/.tart/vms/${vm_name}"
	serial_enable="${SERIAL_ENABLE:-$serial_enable_default}"
	serial_path="${SERIAL_PATH:-$serial_path_default}"
	serial_bridge_enable="${SERIAL_BRIDGE_ENABLE:-$serial_bridge_enable_default}"
	first_boot_attach_disk_path="${vm_disk_dir}/boot.img"
	first_boot_attach_disk_source_path="${FIRST_BOOT_ATTACH_DISK_SOURCE_PATH:-${first_boot_attach_disk_path_default:-}}"
	first_boot_attach_disk_manifest_path="${FIRST_BOOT_ATTACH_DISK_MANIFEST_PATH:-$first_boot_attach_disk_manifest_path_default}"
	first_boot_attach_disk_boot_loader_expected="${FIRST_BOOT_ATTACH_DISK_BOOT_LOADER_EXPECTED:-$first_boot_attach_disk_boot_loader_expected}"
	first_boot_attach_disk_size_gib="${FIRST_BOOT_ATTACH_DISK_SIZE_GIB:-$first_boot_attach_disk_size_gib}"
	sops_age_host_dir="${SOPS_AGE_HOST_DIR:-$sops_age_host_dir_default}"
	sops_age_key_file="${sops_age_host_dir}/keys.txt"
	ndh_toplevel_host_dir="${TOPLEVEL_HOST_DIR:-$ndh_toplevel_host_dir_default}"
	required_disks=(
		"${vm_disk_dir}/disk2.img"
		"${vm_disk_dir}/disk3.img"
		"${vm_disk_dir}/disk4.img"
		"${vm_disk_dir}/recover.img"
	)
}

tart:state:init() {
	extra_run_args=()
	cli_run_args=()
	pending_bootstrap_disk_arg=""
	pending_ndh_toplevel_dir_arg=""
	run_args=()
	root_disk_has_zfs_partition=0
	recovery_mode=0
}

tart:activation:functions:load() {
	if [[ -z "${activation_script_store:-}" ]]; then
		echo "[ERROR] run script missing activation helper path" >&2
		exit 1
	fi

	if [[ ! -r "${activation_script_store}" ]]; then
		echo "[ERROR] activation helper script missing/unreadable: ${activation_script_store}" >&2
		exit 1
	fi

	# shellcheck source=/dev/null
	source "${activation_script_store}"
}

tart:cli:usage() {
	echo "Usage: $0 [--recovery] [-- <additional tart run args>]" >&2
	echo "  --recovery  Attach bootstrap disk even when ZFS root is detected" >&2
}

tart:cli:parse() {
	local arg=""

	while (($# > 0)); do
		arg="$1"
		case "$arg" in
			--recovery)
				recovery_mode=1
				;;
			--help|-h)
				tart:cli:usage
				exit 0
				;;
			--)
				shift
				while (($# > 0)); do
					cli_run_args+=("$1")
					shift
				done
				break
				;;
			*)
				cli_run_args+=("$arg")
				;;
		esac
		shift
	done
}

tart:runtime:validate() {
	if [[ -z "${vm_name:-}" ]]; then
		echo "[ERROR] vm_name not set by run manifest: ${manifest_path}" >&2
		exit 1
	fi

	if [[ -z "${tart_bin}" || ! -x "${tart_bin}" ]]; then
		echo "[ERROR] tart CLI not found at configured path: ${tart_bin}" >&2
		exit 1
	fi
}

tart:disk:required:validate() {
	local disk=""
	for disk in "${required_disks[@]}"; do
		if [[ ! -f "${disk}" ]]; then
			echo "[ERROR] missing required data disk: ${disk}" >&2
			echo "[ERROR] run activation/materializer first to provision VM-local required disks (disk2/disk3/recover)" >&2
			exit 1
		fi
	done
}

tart:run-args:init() {
	run_args=(run "${vm_name}")

	# shellcheck disable=SC2154  # defined in dynamically-sourced activation script
	if tart:bool:is-true "$use_vnc_experimental"; then
		run_args+=(--vnc-experimental)
	fi
}

tart:root-disk:zfs:detect() {
	# shellcheck disable=SC2034  # consumed by activation functions loaded via dynamic source
	TART_LOG_PREFIX=""
	if tart:root-disk:zfs:contains "${vm_disk_dir}/disk.img"; then
		root_disk_has_zfs_partition=1
	fi
}

tart:bootstrap:ndh-share:plan() {
	if [[ "$root_disk_has_zfs_partition" != "0" ]] || [[ -z "$ndh_toplevel_host_dir" ]]; then
		return 0
	fi

	if [[ ! -d "$ndh_toplevel_host_dir" ]]; then
		echo "[ERROR] configured NDH top-level host dir missing: ${ndh_toplevel_host_dir}" >&2
		exit 1
	fi

	# shellcheck disable=SC2154  # ndh_toplevel_tag/sops_age_tag defined in dynamically-sourced activation script
	pending_ndh_toplevel_dir_arg="--dir=${ndh_toplevel_host_dir}:rw,tag=${ndh_toplevel_tag}"
	echo "[INFO] blank/bootstrap root detected; exporting NDH top-level dir: ${ndh_toplevel_host_dir} (tag=${ndh_toplevel_tag})" >&2
}

tart:bootstrap:disk:regenerate() {
	if [[ -z "$first_boot_attach_disk_source_path" ]]; then
		echo "[ERROR] --recovery requested and bootstrap disk is missing, but no bootstrap source path is configured" >&2
		exit 1
	fi

	# shellcheck disable=SC2034  # consumed by activation functions loaded via dynamic source
	TART_LOG_PREFIX=""
	if ! tart:bootstrap:disk:sync-from-source \
		"$first_boot_attach_disk_source_path" \
		"$first_boot_attach_disk_path" \
		"$first_boot_attach_disk_size_gib"; then
		echo "[ERROR] --recovery requested and bootstrap disk is missing: ${first_boot_attach_disk_path}" >&2
		echo "[ERROR] bootstrap source image could not be materialized: ${first_boot_attach_disk_source_path}" >&2
		exit 1
	fi

	echo "[INFO] regenerated missing bootstrap disk for --recovery: ${first_boot_attach_disk_path} (source=${first_boot_attach_disk_source_path})" >&2
}

tart:bootstrap:disk-attach:plan() {
	if [[ -z "$first_boot_attach_disk_path" ]]; then
		return 0
	fi

	if [[ -n "$first_boot_attach_disk_manifest_path" && -n "$first_boot_attach_disk_boot_loader_expected" ]]; then
		# shellcheck disable=SC2034  # consumed by activation functions loaded via dynamic source
		TART_LOG_PREFIX=""
		if ! tart:bootstrap:manifest:bootloader:validate "$first_boot_attach_disk_manifest_path" "$first_boot_attach_disk_boot_loader_expected"; then
			exit 1
		fi
	fi

	if [[ "$root_disk_has_zfs_partition" == "1" ]]; then
		if ((recovery_mode == 1)); then
			if [[ ! -f "$first_boot_attach_disk_path" ]]; then
				tart:bootstrap:disk:regenerate
			fi
			pending_bootstrap_disk_arg="--disk=${first_boot_attach_disk_path}"
			echo "[WARN] --recovery enabled; attaching bootstrap disk despite ZFS root: ${first_boot_attach_disk_path}" >&2
			return 0
		fi

		if [[ -f "$first_boot_attach_disk_path" ]]; then
			rm -f "$first_boot_attach_disk_path"
			echo "[INFO] root disk already contains ZFS partition; removed stale bootstrap disk: ${first_boot_attach_disk_path}" >&2
		fi
		echo "[INFO] root disk already contains ZFS partition; skipping bootstrap disk attach (use --recovery and regenerate bootstrap disk to re-attach)" >&2
		return 0
	fi

	if [[ ! -f "$first_boot_attach_disk_path" ]]; then
		echo "[ERROR] configured bootstrap disk missing: ${first_boot_attach_disk_path}" >&2
		exit 1
	fi

	pending_bootstrap_disk_arg="--disk=${first_boot_attach_disk_path}"
	echo "[INFO] root disk has no ZFS partition; bootstrap disk will be attached last: ${first_boot_attach_disk_path}" >&2
}

tart:serial:run-arg:add() {
	if tart:bool:is-true "${serial_enable:-0}" || [[ -n "${serial_path:-}" ]] || tart:bool:is-true "${serial_bridge_enable:-0}"; then
		echo "[WARN] serial handling is temporarily disabled; ignoring serial flags/paths" >&2
	fi
}

tart:run-args:extra:add() {
	if ((${#cli_run_args[@]} > 0)); then
		run_args+=("${cli_run_args[@]}")
	fi

	if [[ -n "$extra_run_args_raw" ]]; then
		read -r -a extra_run_args <<<"$extra_run_args_raw"
		run_args+=("${extra_run_args[@]}")
	fi
}

tart:run-args:bridge-network:add() {
	if [[ -n "$bridge_interface" ]]; then
		run_args+=("--net-bridged=${bridge_interface}")
	fi
}

tart:share:sops:validate() {
	if [[ ! -d "$sops_age_host_dir" ]]; then
		echo "[ERROR] required SOPS age share directory missing: ${sops_age_host_dir}" >&2
		echo "[ERROR] bootstrap flow requires host keys at ${sops_age_key_file}" >&2
		exit 1
	fi

	if [[ ! -r "$sops_age_key_file" ]]; then
		echo "[ERROR] required SOPS age key file missing/unreadable: ${sops_age_key_file}" >&2
		echo "[ERROR] bootstrap flow requires this file for in-guest secret decryption" >&2
		exit 1
	fi
}

tart:run-args:host-shares:add() {
	# shellcheck disable=SC2154  # sops_age_tag defined in dynamically-sourced activation script
	run_args+=("--dir=${sops_age_host_dir}:ro,tag=${sops_age_tag}")

	if [[ -n "$pending_ndh_toplevel_dir_arg" ]]; then
		run_args+=("$pending_ndh_toplevel_dir_arg")
	fi
}

tart:run-args:required-disks:add() {
	local disk=""
	for disk in "${required_disks[@]}"; do
		run_args+=("--disk=${disk}:sync=none,caching=cached")
	done
}

tart:run-args:bootstrap-disk:add() {
	if [[ -n "$pending_bootstrap_disk_arg" ]]; then
		run_args+=("$pending_bootstrap_disk_arg")
	fi
}

tart:run:execute() {
	exec "${tart_bin}" "${run_args[@]}"
}

tart:run:main() {
	tart:manifest:load
	tart:activation:functions:load
	tart:state:init
	tart:cli:parse "$@"
	tart:runtime:configure
	tart:runtime:validate
	tart:disk:required:validate
	tart:run-args:init
	tart:root-disk:zfs:detect
	tart:bootstrap:ndh-share:plan
	tart:bootstrap:disk-attach:plan
	tart:serial:run-arg:add
	tart:run-args:extra:add
	tart:run-args:bridge-network:add
	tart:share:sops:validate
	tart:run-args:host-shares:add
	tart:run-args:required-disks:add
	tart:run-args:bootstrap-disk:add
	tart:run:execute
}

tart:run:main "$@"
