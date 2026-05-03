#!/usr/bin/env -S bash -euxo pipefail
# shellcheck disable=SC1091,SC2016,SC2154
# SC2016: yq expressions use single quotes intentionally (not bash variable expansion)
# SC2154: use_vnc_experimental, sops_age_tag, bridge_interface, tart_bin,
#         diskutil_bin, etc. are loaded dynamically from the run manifest via tart:manifest:load
source "@nixBashTrampoline@"

manifest_path="@rawImageTargetPath@/manifest.yaml"
extra_run_args_raw="${RUN_EXTRA_ARGS:-}"

tart:bool:is-true() {
	local value="${1:-}"
	value="${value,,}"
	[[ "$value" == "1" || "$value" == "true" || "$value" == "yes" || "$value" == "on" ]]
}

tart:manifest:images:enumerate() {
	# Yields: <name>\t<role> for every disk image in the bringup manifest.
	# Reads from the gcroot path so we always use the current activation's images.
	local manifest_path="${raw_image_manifest_path:-}"
	local primary_img primary_name manifest_dir image_count img_file img_name img_role
	[[ -n "$manifest_path" && -r "$manifest_path" ]] || return 0

	primary_img="$(yq -p=yaml -r '.imagePath // ""' "$manifest_path" 2>/dev/null || true)"
	primary_name="${primary_img%.img}"
	manifest_dir="$(dirname "$manifest_path")"
	image_count="$(yq -p=yaml -r '.images | length' "$manifest_path" 2>/dev/null || echo 0)"

	if ((image_count > 0)); then
		yq -p=yaml -r '.images[]? | [(.name // ""), (.role // "")] | @tsv' "$manifest_path"
		return
	fi

	# Fallback: scan manifest directory for *.img files (symlinks or regular files)
	while IFS= read -r img_file; do
		img_name="$(basename "$img_file" .img)"
		if [[ -n "$primary_name" && "$img_name" == "$primary_name" ]]; then
			img_role="primary"
		else
			img_role=""
		fi
		printf '%s\t%s\n' "$img_name" "$img_role"
	done < <(find "$manifest_dir" -maxdepth 1 \( -type f -o -type l \) -name '*.img' 2>/dev/null | LC_ALL=C sort)
}

# ─────────────────────────────────────────────────────────────────────────────

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
	serial_bridge_auto_screen="${SERIAL_BRIDGE_AUTO_SCREEN:-$serial_bridge_auto_screen_default}"
	no_graphics="${NO_GRAPHICS:-$no_graphics_default}"
	sops_age_host_dir="${SOPS_AGE_HOST_DIR:-$sops_age_host_dir_default}"
	sops_age_key_file="${sops_age_host_dir}/age/keys.txt"

	# Derive the bringup manifest: first follow the gcroot bundle (stable, GC-safe),
	# then fall back to the store path baked into the run manifest.
	raw_image_manifest_path=""
	local gcroot_path="${raw_image_target_path_default:-}"
	if [[ -n "$gcroot_path" && -L "$gcroot_path" ]]; then
		local bundle_dir
		bundle_dir="$(readlink -f "$gcroot_path" 2>/dev/null || true)"
		local bundle_manifest="${bundle_dir}/bringup-manifest/manifest.yaml"
		if [[ -r "$bundle_manifest" ]]; then
			raw_image_manifest_path="$bundle_manifest"
		fi
	fi
	if [[ -z "$raw_image_manifest_path" ]]; then
		local store_path="${raw_image_store_path_default:-}"
		if [[ -n "$store_path" && -f "$store_path" ]]; then
			local candidate
			candidate="$(dirname "$store_path")/manifest.yaml"
			if [[ -r "$candidate" ]]; then
				raw_image_manifest_path="$candidate"
			fi
		fi
	fi

	required_disks=()
	local image_name image_role
	while IFS=$'\t' read -r image_name image_role; do
		[[ -n "$image_name" && "$image_role" != "primary" ]] || continue
		required_disks+=("${vm_disk_dir}/${image_name}.img")
	done < <(tart:manifest:images:enumerate)

	if [[ ${#required_disks[@]} -eq 0 ]]; then
		required_disks=(
			"${vm_disk_dir}/tank1.img"
			"${vm_disk_dir}/tank2.img"
			"${vm_disk_dir}/tank3.img"
			"${vm_disk_dir}/recover.img"
		)
	fi
}

tart:state:init() {
	extra_run_args=()
	cli_run_args=()
	run_args=()
}

tart:cli:usage() {
	echo "Usage: $0 [-- <additional tart run args>]" >&2
}

tart:cli:parse() {
	local arg=""

	while (($# > 0)); do
		arg="$1"
		case "$arg" in
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

	if tart:bool:is-true "$no_graphics"; then
		run_args+=(--no-graphics)
	elif tart:bool:is-true "$use_vnc_experimental"; then
		# --vnc-experimental and --no-graphics are mutually exclusive
		run_args+=(--vnc-experimental)
	fi
}

tart:serial:bridge:start() {
	# tart --serial-path requires a real PTY character device (not a Unix socket).
	# socat bridges two PTYs: tart opens one end, the user attaches to the other.
	local bridge_dir="$1"
	local tart_pty="${bridge_dir}/${vm_name}.tart"
	local user_pty="${bridge_dir}/${vm_name}.screen"

	if ! command -v socat >/dev/null 2>&1; then
		echo "[ERROR] socat is required for serial bridge mode but was not found in PATH" >&2
		return 1
	fi

	mkdir -p "$bridge_dir"

	# Remove stale symlinks from a prior run
	rm -f "$tart_pty" "$user_pty"

	socat \
		PTY,link="${tart_pty}",raw,echo=0 \
		PTY,link="${user_pty}",raw,echo=0 \
		&
	local socat_pid=$!

	# Wait until both symlinks appear (up to 3 s)
	local i=0
	while [[ ! -e "$tart_pty" || ! -e "$user_pty" ]] && ((i++ < 30)); do
		sleep 0.1
	done

	if [[ ! -e "$tart_pty" || ! -e "$user_pty" ]]; then
		echo "[ERROR] socat PTY bridge did not start in time (pid=${socat_pid})" >&2
		kill "$socat_pid" 2>/dev/null || true
		return 1
	fi

	echo "[INFO] serial bridge ready — attach with: screen ${user_pty}" >&2
	echo "[INFO]   tart PTY : ${tart_pty}" >&2
	echo "[INFO]   user PTY : ${user_pty}" >&2
}

tart:serial:screen:start() {
	local user_pty="$1"
	local tart_pty="$2"
	local screen_session="${vm_name}"
	local serial_log="${vm_disk_dir}/serial.log"

	if ! command -v screen >/dev/null 2>&1; then
		echo "[WARN] screen not found in PATH; attach manually: screen ${user_pty}" >&2
		return 0
	fi

	# Quit any stale session with the same name
	screen -S "${screen_session}" -X quit 2>/dev/null || true

	# Write a relay script that bridges I/O between the screen window and the
	# serial PTY pair.  Running as the screen window process means it receives
	# SIGWINCH whenever the outer terminal resizes, so it can propagate the new
	# dimensions to the VM-facing PTY (tart_pty).
	local relay_script
	relay_script=$(mktemp "${TMPDIR:-/tmp}/ndh-relay-XXXXXX.sh")
	chmod +x "$relay_script"
	cat > "$relay_script" << 'RELAY_EOF'
#!/usr/bin/env bash
# Serial-console relay: bridges screen window ↔ socat PTY pair and propagates
# terminal resize events (SIGWINCH) to the VM-facing PTY.
tart_pty="${1:?tart_pty required}"
user_pty="${2:?user_pty required}"

pty_resize() {
	local rows cols
	IFS=' ' read -r rows cols < <(stty size 2>/dev/null) || { rows=24; cols=80; }
	stty rows "$rows" cols "$cols" < "$tart_pty" 2>/dev/null || true
}
trap pty_resize WINCH

# Raw mode: bytes flow through the relay unmodified; screen handles display.
stty raw -echo 2>/dev/null || true

# Apply the current screen window size to the VM PTY immediately.
pty_resize

# Open the socat bridge PTY bidirectionally on fd 3.
exec 3<>"$user_pty"

# Both I/O directions as background jobs so bash keeps control of the
# process group and can deliver SIGWINCH to our trap handler.
cat <&3 &
relay_cat_pid=$!
cat >&3 &
input_cat_pid=$!

# wait is interruptible: SIGWINCH fires pty_resize, then we loop back.
while kill -0 "$relay_cat_pid" 2>/dev/null || kill -0 "$input_cat_pid" 2>/dev/null; do
	wait 2>/dev/null || true
done

kill "$relay_cat_pid" "$input_cat_pid" 2>/dev/null || true
exec 3>&-
RELAY_EOF

	screen -dmS "${screen_session}" -L -Logfile "${serial_log}" "$relay_script" "$tart_pty" "$user_pty"

	# Remove the relay script once screen has had time to exec it.
	(sleep 2 && rm -f "$relay_script") &

	echo "[INFO] serial screen session '${screen_session}' started → logging to ${serial_log}" >&2
	echo "[INFO]   reattach with: screen -r ${screen_session}" >&2
	echo "[INFO]   terminal resize is propagated automatically via SIGWINCH" >&2
}

tart:serial:run-arg:add() {
	if tart:bool:is-true "${serial_bridge_enable:-0}"; then
		# Bridge mode: socat creates a PTY pair; tart opens one end, user attaches to the other.
		local bridge_dir="${serial_bridge_dir:-${HOME}/.tart/vms/${vm_name}/serial}"
		local tart_pty="${bridge_dir}/${vm_name}.tart"
		local user_pty="${bridge_dir}/${vm_name}.screen"
		tart:serial:bridge:start "$bridge_dir"
		run_args+=("--serial-path=${tart_pty}")
		if tart:bool:is-true "${serial_bridge_auto_screen:-0}"; then
			tart:serial:screen:start "${user_pty}" "${tart_pty}"
		fi
	elif [[ -n "${serial_path:-}" ]]; then
		# Caller manages the PTY; just pass it through.
		run_args+=("--serial-path=${serial_path}")
		echo "[INFO] serial path: ${serial_path}" >&2
	elif tart:bool:is-true "${serial_enable:-0}"; then
		# Let tart allocate its own PTY and print the path.
		run_args+=("--serial")
		echo "[INFO] serial console enabled (--serial)" >&2
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
	run_args+=("--dir=${sops_age_host_dir}:ro,tag=${sops_age_tag}")
}

tart:run-args:required-disks:add() {
	local disk=""
	for disk in "${required_disks[@]}"; do
		run_args+=("--disk=${disk}:sync=none,caching=cached")
	done
}

tart:run:execute() {
	exec "${tart_bin}" "${run_args[@]}"
}

tart:run:main() {
	tart:manifest:load
	tart:state:init
	tart:cli:parse "$@"
	tart:runtime:configure
	tart:runtime:validate
	tart:disk:required:validate
	tart:run-args:init
	tart:serial:run-arg:add
	tart:run-args:extra:add
	tart:run-args:bridge-network:add
	tart:share:sops:validate
	tart:run-args:host-shares:add
	tart:run-args:required-disks:add
	tart:run:execute
}

tart:run:main "$@"
