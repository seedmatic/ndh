set -euo pipefail

if ! command -v tart >/dev/null 2>&1; then
  echo "[bootstrap-lab][ERROR] tart CLI not found in PATH" >&2
  exit 1
fi
if ! command -v diskutil >/dev/null 2>&1; then
  echo "[bootstrap-lab][ERROR] diskutil required for ASIF conversion (Darwin host)." >&2
  exit 1
fi

VM_NAME="${VM_NAME:-@DEFAULT_VM_NAME@}"
TART_HOME="${TART_HOME:-$HOME/.tart}"
VM_DIR="${VM_DIR:-$TART_HOME/vms/$VM_NAME}"
FACTORY_RESET="${FACTORY_RESET:-1}"
WRAPPER_TEMPLATE="@WRAPPER_TEMPLATE_PATH@"

raw_out="$(nix build -L -v -v --no-link --print-out-paths .#@IMAGE_ATTR@)"
raw_img="$raw_out/nixos.img"

mkdir -p "$VM_DIR"

convert_one() {
  local input="$1"
  local output="$2"
  local base
  base="$output"

  rm -f "$output" "$base.asif" "$base.dmg"
  diskutil image create from "$input" --format ASIF "$base" >/dev/null

  if [[ -e "$base.asif" ]]; then
    mv -f "$base.asif" "$output"
  elif [[ -e "$base.dmg" ]]; then
    mv -f "$base.dmg" "$output"
  elif [[ ! -e "$output" ]]; then
    echo "[bootstrap-lab][ERROR] diskutil produced no ASIF output for $input" >&2
    exit 1
  fi

  chmod 0644 "$output" || true
  chmod u+w "$output" || true
  echo "[bootstrap-lab] wrote $output"
}

bool_true() {
  local v="${1:-}"
  v="${v,,}"
  [[ "$v" == "1" || "$v" == "true" || "$v" == "yes" || "$v" == "on" ]]
}

if bool_true "$FACTORY_RESET"; then
  echo "[bootstrap-lab] factory reset VM: $VM_NAME"
  tart stop "$VM_NAME" >/dev/null 2>&1 || true
  tart delete "$VM_NAME" >/dev/null 2>&1 || true
  rm -rf "$VM_DIR"
  mkdir -p "$VM_DIR"
  tart create --linux "$VM_NAME"
else
  if ! tart list 2>/dev/null | sed -E 's/^[[:space:]]+//' | tr -s ' ' | cut -d' ' -f1 | grep -qx "$VM_NAME"; then
    echo "[bootstrap-lab] creating Tart VM: $VM_NAME"
    tart create --linux "$VM_NAME"
  fi
  tart stop "$VM_NAME" >/dev/null 2>&1 || true
fi

convert_one "$raw_img" "$VM_DIR/disk.img"

wrapper="$TART_HOME/vms/$VM_NAME.sh"
cat "$WRAPPER_TEMPLATE" >"$wrapper"
chmod +x "$wrapper"

echo "[bootstrap-lab] materialized Tart VM assets"
echo "[bootstrap-lab] vm_dir=$VM_DIR"
echo "[bootstrap-lab] wrapper=$wrapper"
