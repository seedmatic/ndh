#!/usr/bin/env bash
set -euo pipefail

BOOT_MNT="${BOOT_MNT:-/boot}"
BOOTFS="${BOOTFS:-tank/root}"
ZBM_DIR="$BOOT_MNT/EFI/ZBM"
ZBM_EFI_SOURCE="${ZBM_EFI_SOURCE:-}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "[zbootmenu][ERROR] run as root" >&2
  exit 1
fi

if [[ ! -d "$BOOT_MNT" ]]; then
  echo "[zbootmenu][ERROR] boot mount missing: $BOOT_MNT" >&2
  exit 1
fi

mkdir -p "$ZBM_DIR"

system_link="$(readlink -f /nix/var/nix/profiles/system)"
kernel_src="$(readlink -f /nix/var/nix/profiles/system/kernel)"
initrd_src="$(readlink -f /nix/var/nix/profiles/system/initrd)"
init_path="$system_link/init"

kernel_dst="$BOOT_MNT/vmlinuz-$(basename "$kernel_src")"
initrd_dst="$BOOT_MNT/initramfs-$(basename "$initrd_src")"

cp -f "$kernel_src" "$kernel_dst"
cp -f "$initrd_src" "$initrd_dst"

cmdline="init=$init_path loglevel=7 console=hvc0 console=ttyAMA0,115200n8"
zfs set org.zfsbootmenu:commandline="$cmdline" "$BOOTFS"

arch="$(uname -m)"
if [[ -z "$ZBM_EFI_SOURCE" ]]; then
  if [[ -f /opt/tart/zbootmenu/VMLINUZ.EFI ]]; then
    ZBM_EFI_SOURCE=/opt/tart/zbootmenu/VMLINUZ.EFI
  elif [[ "$arch" == "x86_64" ]]; then
    curl -fL https://get.zfsbootmenu.org/efi -o "$ZBM_DIR/VMLINUZ.EFI"
  fi
fi

if [[ "$arch" != "x86_64" && -z "$ZBM_EFI_SOURCE" ]]; then
  echo "[zbootmenu][ERROR] no aarch64 prebuilt EFI available; provide ZBM_EFI_SOURCE path" >&2
  exit 2
fi

if [[ -n "$ZBM_EFI_SOURCE" ]]; then
  if [[ ! -f "$ZBM_EFI_SOURCE" ]]; then
    echo "[zbootmenu][ERROR] ZBM_EFI_SOURCE not found: $ZBM_EFI_SOURCE" >&2
    exit 1
  fi
  cp -f "$ZBM_EFI_SOURCE" "$ZBM_DIR/VMLINUZ.EFI"
fi
cp -f "$ZBM_DIR/VMLINUZ.EFI" "$ZBM_DIR/VMLINUZ-BACKUP.EFI"

if [[ -d "$BOOT_MNT/loader/entries" ]]; then
  cat > "$BOOT_MNT/loader/entries/zbootmenu.conf" <<'EOF'
title ZBootMenu
efi /EFI/ZBM/VMLINUZ.EFI
options zbm.show
EOF
fi

echo "[zbootmenu] installed"
echo "[zbootmenu] kernel=$kernel_dst"
echo "[zbootmenu] initrd=$initrd_dst"
echo "[zbootmenu] bootfs=$BOOTFS"
