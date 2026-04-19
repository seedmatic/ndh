set -euo pipefail

SUDO_BIN="/run/wrappers/bin/sudo"
if [[ ! -x "$SUDO_BIN" ]]; then
  SUDO_BIN="$(command -v sudo)"
fi

if ! "$SUDO_BIN" -n true >/dev/null 2>&1; then
  echo "[zbootmenu-efi][ERROR] passwordless sudo is required on builder host" >&2
  exit 1
fi

DEST_PATH="${1:-$PWD/VMLINUZ.EFI}"
WORKDIR="$(mktemp -d /tmp/zbm-builder-XXXXXX)"
BOOT_MNT="$WORKDIR/boot"
OUT_DIR="$WORKDIR/out"
DRACUT_DIR="$WORKDIR/dracut.conf.d"
LOG_FILE="$WORKDIR/build.log"

mkdir -p "$BOOT_MNT" "$OUT_DIR" "$DRACUT_DIR"

"$SUDO_BIN" -n mount -t tmpfs tmpfs "$BOOT_MNT"
trap '"$SUDO_BIN" -n umount "$BOOT_MNT" >/dev/null 2>&1 || true' EXIT

KERNEL_PATH="$(readlink -f /run/current-system/kernel)"
KMODDIR="$(readlink -f /run/current-system/kernel-modules/lib/modules/*)"
KVER="$(basename "$KMODDIR")"
STUB_PATH="@STUB_PATH@"
CLEAN_PATH="@CLEAN_PATH@"

export PATH="$CLEAN_PATH"
export DRACUT_INSTALL_PATH="$CLEAN_PATH"
export DRACUT_PATH="$CLEAN_PATH"

# Dracut and helper scripts frequently probe fixed FHS locations.
# Ensure critical commands are available there.
for cmd in systemctl udevadm depmod modprobe rmmod mount umount reboot halt poweroff; do
  src="$(command -v "$cmd" || true)"
  if [[ -n "$src" ]]; then
    "$SUDO_BIN" -n mkdir -p /usr/bin /usr/sbin /bin /sbin
    "$SUDO_BIN" -n ln -sfn "$src" "/usr/bin/$cmd"
    "$SUDO_BIN" -n ln -sfn "$src" "/usr/sbin/$cmd"
    "$SUDO_BIN" -n ln -sfn "$src" "/bin/$cmd"
    "$SUDO_BIN" -n ln -sfn "$src" "/sbin/$cmd"
  fi
done

cat > "$WORKDIR/config.yaml" <<CFG
Global:
  ManageImages: true
  BootMountPoint: $BOOT_MNT
  DracutConfDir: $DRACUT_DIR
  DracutFlags:
    - --kmoddir
    - $KMODDIR
Components:
  ImageDir: $OUT_DIR
  Versions: false
  Enabled: true
EFI:
  ImageDir: $OUT_DIR
  Versions: false
  Enabled: true
  Stub: $STUB_PATH
Kernel:
  CommandLine: zbm.show loglevel=7 console=hvc0 console=ttyAMA0,115200n8
CFG

generate-zbm \
  --no-initcpio \
  --config "$WORKDIR/config.yaml" \
  --kernel "$KERNEL_PATH" \
  --kver "$KVER" \
  --debug >"$LOG_FILE" 2>&1 || {
  echo "[zbootmenu-efi][ERROR] generate-zbm failed" >&2
  tail -n 120 "$LOG_FILE" >&2 || true
  exit 1
}

EFI_FILE="$(find "$OUT_DIR" -maxdepth 1 -type f -name '*.EFI' | head -n1)"
if [[ -z "$EFI_FILE" ]]; then
  echo "[zbootmenu-efi][ERROR] no EFI output found" >&2
  tail -n 120 "$LOG_FILE" >&2 || true
  exit 1
fi

mkdir -p "$(dirname "$DEST_PATH")"
cp -f "$EFI_FILE" "$DEST_PATH"
chmod u+rw "$DEST_PATH"
echo "[zbootmenu-efi] wrote $DEST_PATH"
