set -euo pipefail

DEST_DIR="${DEST_DIR:-$PWD/.tart/opt/zbootmenu}"
ZBOOTMENU_EFI_ATTR="@ZBOOTMENU_EFI_ATTR@"
ZBM_BUILDER_HOST="${ZBM_BUILDER_HOST:-builder@linux-builder}"
REMOTE_EFI_PATH="${REMOTE_EFI_PATH:-/tmp/zbm-vmlinuz.efi}"

builder_out="$(nix build -L --no-link --print-out-paths .#${ZBOOTMENU_EFI_ATTR})"
nix copy --to "ssh-ng://${ZBM_BUILDER_HOST}" "$builder_out"

ssh -o BatchMode=yes "$ZBM_BUILDER_HOST" "$builder_out/bin/zbootmenu-efi-builder '$REMOTE_EFI_PATH'"

mkdir -p "$DEST_DIR"
scp -o BatchMode=yes "$ZBM_BUILDER_HOST:$REMOTE_EFI_PATH" "$DEST_DIR/VMLINUZ.EFI"
chmod u+rw "$DEST_DIR/VMLINUZ.EFI"

echo "[zbootmenu] EFI materialized"
echo "[zbootmenu] source=generated on $ZBM_BUILDER_HOST by $builder_out/bin/zbootmenu-efi-builder"
echo "[zbootmenu] dest=$DEST_DIR/VMLINUZ.EFI"
