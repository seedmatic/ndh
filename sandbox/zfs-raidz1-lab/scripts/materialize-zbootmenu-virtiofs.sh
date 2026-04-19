set -euo pipefail

SHARE_ROOT="${SHARE_ROOT:-$PWD/.local.d/share}"
SHARE_TAG="${SHARE_TAG:-tart}"
DEST_DIR="$SHARE_ROOT/$SHARE_TAG/zbootmenu"
BUNDLE_ATTR="@BUNDLE_ATTR@"

bundle_out="$(nix build -L --no-link --print-out-paths .#${BUNDLE_ATTR})"

mkdir -p "$DEST_DIR"
cp -f "$bundle_out/share/zbootmenu"/* "$DEST_DIR/"
chmod -R u+rwX "$DEST_DIR"

echo "[zbootmenu] bundle materialized"
echo "[zbootmenu] dest=$DEST_DIR"
echo "[zbootmenu] guest path (tag=$SHARE_TAG) => /opt/$SHARE_TAG/zbootmenu"
echo "[zbootmenu] run in guest: /opt/$SHARE_TAG/zbootmenu/install-zbootmenu-in-guest.sh"
