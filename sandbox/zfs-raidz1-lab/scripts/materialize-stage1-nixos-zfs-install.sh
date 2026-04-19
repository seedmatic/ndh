set -euo pipefail

TART_HOME="${TART_HOME:-$PWD/.tart}"
VM_NAME="${VM_NAME:-nixos-installer}"
VM_DIR="${VM_DIR:-${TART_HOME}/vms/${VM_NAME}}"
OPT_DIR="${OPT_DIR:-${VM_DIR}/opt}"
OPT_BIN_DIR="${OPT_DIR}/bin"
SRC_SCRIPT="@STAGE1_SCRIPT_PATH@"
DEST_SCRIPT="${OPT_BIN_DIR}/stage1-nixos-zfs-install.sh"

if [[ "$SRC_SCRIPT" == "@STAGE1_SCRIPT_PATH@" ]]; then
	SRC_SCRIPT="$PWD/scripts/stage1-nixos-zfs-install.sh"
fi

if [[ ! -f "$SRC_SCRIPT" ]]; then
	echo "[stage1-lab][ERROR] source script not found: $SRC_SCRIPT" >&2
	exit 1
fi

mkdir -p "$OPT_BIN_DIR"
cp "$SRC_SCRIPT" "$DEST_SCRIPT"
chmod 0755 "$DEST_SCRIPT"

echo "[stage1-lab] staged guest script: $DEST_SCRIPT"
echo "[stage1-lab] inside nixos-installer, run:"
echo "[stage1-lab]   sudo /opt/bin/stage1-nixos-zfs-install.sh"
