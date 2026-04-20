#!/usr/bin/env -S bash -euxo pipefail
# shellcheck disable=SC1091
source "@bashTrampoline@"

vm_name="@vmName@"
disk_dir="${HOME}/.tart/disks/${vm_name}"
bridge_interface="@vmRunBridgeInterface@"
use_vnc_experimental="@vmRunUseVncExperimental@"
sops_age_share_enable="@vmRunSopsAgeShareEnable@"
sops_age_host_dir="@vmRunSopsAgeHostDir@"
sops_age_tag="@vmRunSopsAgeTag@"
tart_bin="@tartBinaryPath@"
extra_run_args_raw="${NDH_TART_RUN_EXTRA_ARGS:-}"
extra_run_args=()

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
