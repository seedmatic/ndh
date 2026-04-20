#!/usr/bin/env -S bash -euxo pipefail
# shellcheck disable=SC1091
source "@bashTrampoline@"

vm_name="@vmName@"
disk_dir="${HOME}/.tart/disks/${vm_name}"
bridge_interface="@vmRunBridgeInterface@"
use_vnc_experimental="@vmRunUseVncExperimental@"
serial_enable_default="@vmRunSerialEnable@"
serial_path_default="@vmRunSerialPath@"
serial_bridge_enable_default="@vmRunSerialBridgeEnable@"
serial_bridge_dir_default="@vmRunSerialBridgeDir@"
sops_age_share_enable="@vmRunSopsAgeShareEnable@"
sops_age_host_dir="@vmRunSopsAgeHostDir@"
sops_age_tag="@vmRunSopsAgeTag@"
tart_bin="@tartBinaryPath@"
extra_run_args_raw="${NDH_TART_RUN_EXTRA_ARGS:-}"
serial_enable="${NDH_TART_SERIAL_ENABLE:-$serial_enable_default}"
serial_path="${NDH_TART_SERIAL_PATH:-$serial_path_default}"
serial_bridge_enable="${NDH_TART_SERIAL_BRIDGE_ENABLE:-$serial_bridge_enable_default}"
serial_path_unsafe_allow="${NDH_TART_SERIAL_PATH_UNSAFE_ALLOW:-0}"
serial_bridge_dir="${NDH_TART_SERIAL_BRIDGE_DIR:-$serial_bridge_dir_default}"
serial_bridge_name="${NDH_TART_SERIAL_BRIDGE_NAME:-$vm_name}"
extra_run_args=()

tart_bool_is_true() {
	local v="${1:-}"
	v="${v,,}"
	[[ "$v" == "1" || "$v" == "true" || "$v" == "yes" || "$v" == "on" ]]
}

required_disks=(
	"${disk_dir}/tank1.asif"
	"${disk_dir}/tank2.asif"
	"${disk_dir}/tank3.asif"
	"${disk_dir}/recover.asif"
)

if [[ -z "${tart_bin}" || ! -x "${tart_bin}" ]]; then
	echo "[tart-run][ERROR] tart CLI not found at configured path: ${tart_bin}" >&2
	exit 1
fi

mkdir -p "${disk_dir}"

for disk in "${required_disks[@]}"; do
	if [[ ! -f "${disk}" ]]; then
		echo "[tart-run][ERROR] missing required data disk: ${disk}" >&2
		echo "[tart-run][ERROR] run activation/materializer first to provision external ASIF disks" >&2
		exit 1
	fi
done

run_args=(run "${vm_name}")
if [[ "$use_vnc_experimental" == "1" ]]; then
	run_args+=(--vnc-experimental)
fi

ensure_serial_bridge() {
	local bridge_tart bridge_screen bridge_pid bridge_log
	local pid

	bridge_tart="${serial_bridge_dir}/${serial_bridge_name}.tart"
	bridge_screen="${serial_bridge_dir}/${serial_bridge_name}.screen"
	bridge_pid="${serial_bridge_dir}/${serial_bridge_name}.pid"
	bridge_log="${serial_bridge_dir}/${serial_bridge_name}.log"

	mkdir -p "$serial_bridge_dir"

	if [[ -f "$bridge_pid" ]]; then
		pid="$(cat "$bridge_pid" 2>/dev/null || true)"
		if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && [[ -e "$bridge_tart" ]] && [[ -e "$bridge_screen" ]]; then
			serial_path="$bridge_tart"
			echo "[tart-run][INFO] reusing serial PTY bridge pid=${pid}" >&2
			echo "[tart-run][INFO] attach serial with: screen ${bridge_screen} 115200" >&2
			return 0
		fi
		rm -f "$bridge_pid"
	fi

	rm -f "$bridge_tart" "$bridge_screen"
	if ! command -v socat >/dev/null 2>&1; then
		echo "[tart-run][WARN] socat missing; cannot create stable serial PTY bridge" >&2
		return 1
	fi

	nohup socat \
		pty,raw,echo=0,link="$bridge_tart",mode=600 \
		pty,raw,echo=0,link="$bridge_screen",mode=600 \
		>>"$bridge_log" 2>&1 &
	pid="$!"
	echo "$pid" > "$bridge_pid"

	for _ in {1..50}; do
		if [[ -e "$bridge_tart" ]] && [[ -e "$bridge_screen" ]]; then
			serial_path="$bridge_tart"
			echo "[tart-run][INFO] created serial PTY bridge pid=${pid}" >&2
			echo "[tart-run][INFO] tart endpoint: ${bridge_tart}" >&2
			echo "[tart-run][INFO] screen endpoint: ${bridge_screen}" >&2
			echo "[tart-run][INFO] attach serial with: screen ${bridge_screen} 115200" >&2
			return 0
		fi
		sleep 0.05
	done

	echo "[tart-run][WARN] timed out waiting for serial PTY bridge endpoints" >&2
	return 1
}

if tart_bool_is_true "$serial_enable"; then
	if [[ -n "$serial_path" ]] || tart_bool_is_true "$serial_bridge_enable"; then
		if ! tart_bool_is_true "$serial_path_unsafe_allow"; then
			echo "[tart-run][WARN] serial-path mode is disabled by default due known Tart/VZ regressions" >&2
			echo "[tart-run][WARN] symptoms include serial-only input, missing graphics logs, and high VM CPU" >&2
			echo "[tart-run][WARN] falling back to --serial; set NDH_TART_SERIAL_PATH_UNSAFE_ALLOW=1 to force serial-path" >&2
			serial_path=""
			serial_bridge_enable="0"
		fi
	fi

	if [[ -z "$serial_path" ]] && tart_bool_is_true "$serial_bridge_enable"; then
		ensure_serial_bridge || true
	fi

	if [[ -n "$serial_path" ]]; then
		if [[ -e "$serial_path" ]]; then
			run_args+=("--serial-path=${serial_path}")
			echo "[tart-run][INFO] using serial-path endpoint: ${serial_path}" >&2
		else
			echo "[tart-run][WARN] configured serial path missing: ${serial_path}; falling back to --serial" >&2
			run_args+=(--serial)
		fi
	else
		run_args+=(--serial)
	fi
fi

if [[ -n "$extra_run_args_raw" ]]; then
	read -r -a extra_run_args <<<"$extra_run_args_raw"
	run_args+=("${extra_run_args[@]}")
fi

if [[ -n "$bridge_interface" ]]; then
	run_args+=("--net-bridged=${bridge_interface}")
fi

if [[ "$sops_age_share_enable" == "1" ]]; then
	if [[ -d "$sops_age_host_dir" ]]; then
		run_args+=("--dir=${sops_age_host_dir}:ro,tag=${sops_age_tag}")
	else
		echo "[tart-run][WARN] SOPS age share source directory missing: ${sops_age_host_dir}" >&2
		echo "[tart-run][WARN] guest will not receive host-bound SOPS age key share" >&2
	fi
fi

for disk in "${required_disks[@]}"; do
	run_args+=("--disk=${disk}:sync=none,caching=cached")
done

exec "${tart_bin}" "${run_args[@]}"
