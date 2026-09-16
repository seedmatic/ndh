#!/usr/bin/env bash
# Temporary local aarch64-linux builder for the `bootstrap` phase.
#
# Cold-bootstrap escape (see docs/host-builder-phases.adoc): building the
# embedded nix.linux-builder's own guest is itself an aarch64-linux build, so a
# from-scratch Mac has no builder to build the builder. This launches the STOCK
# vz linux-builder (cache-substitutable, no local aarch64-linux build) and wires
# the nix-daemon to it TEMPORARILY, so `nixos-rebuild switch .#<host>-nixos` can
# offload. Superseded by `ndh.hostBuilder = "steady"` once the sibling is up.
set -euo pipefail

STATE_DIR="${NDH_BOOTSTRAP_BUILDER_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/ndh/linux-builder}"
KEYS_DIR="$STATE_DIR/keys"
# create-builder / run-nixos-vm write the store image + data disk (nixos.qcow2,
# up to diskSize) in the CWD. Pin a dedicated dir on REAL disk (APFS) so they
# don't litter the repo/cwd — and never $TMPDIR (that's a small RAM tmpfs here).
WORK_DIR="$STATE_DIR/vm"
SSH_CONF=/etc/ssh/ssh_config.d/100-linux-builder.conf
MACHINES=/etc/nix/machines
MACHINES_BAK=/etc/nix/machines.pre-bootstrap-builder
KNOWN_HOSTS=/var/root/.ssh/known_hosts.linux-builder
PORT=31022

log() { printf '[bootstrap-linux-builder] %s\n' "$*" >&2; }

teardown() {
  log "removing temporary builder wiring"
  sudo rm -f "$SSH_CONF"
  if sudo test -f "$MACHINES_BAK"; then
    sudo mv -f "$MACHINES_BAK" "$MACHINES"
    log "restored $MACHINES from backup"
  else
    sudo rm -f "$MACHINES"
    log "removed $MACHINES (no prior version to restore)"
  fi
  if pkill -f 'bin/vzvm' 2>/dev/null; then
    log "stopped the vz builder VM"
  fi
  rm -rf "$STATE_DIR"
  log "removed state dir $STATE_DIR"
  log "done — flip ndh.hostBuilder to steady + darwin-rebuild switch for the durable wiring"
}

# EXIT trap: the builder just stopped (Ctrl-C, poweroff, crash). Don't tear down
# behind the operator's back — a build may still be running in another terminal.
# Ask; default no, so the wiring survives an accidental interrupt.
on_exit() {
  printf '\n' >&2
  local ans=""
  if [ -e /dev/tty ]; then
    read -r -p "[bootstrap-linux-builder] builder stopped — remove wiring + state dir now? [y/N] " ans </dev/tty >/dev/tty 2>&1 || ans=""
  fi
  case "$ans" in
    [yY] | [yY][eE][sS]) teardown ;;
    *) log "left wiring + state dir in place — tear down later with: bootstrap-linux-builder --stop" ;;
  esac
}

wire() {
  log "authorizing sudo for the root-owned wiring"
  sudo -v
  log "writing ssh alias -> $SSH_CONF"
  sudo tee "$SSH_CONF" >/dev/null <<EOF
Host linux-builder
  HostName localhost
  Port $PORT
  User builder
  IdentityFile /etc/nix/builder_ed25519
  StrictHostKeyChecking accept-new
  UserKnownHostsFile $KNOWN_HOSTS
EOF
  if sudo test -f "$MACHINES" && ! sudo test -f "$MACHINES_BAK"; then
    sudo cp "$MACHINES" "$MACHINES_BAK"
    log "backed up existing $MACHINES -> $MACHINES_BAK"
  fi
  sudo tee "$MACHINES" >/dev/null <<EOF
ssh-ng://builder@linux-builder aarch64-linux /etc/nix/builder_ed25519 8 1 big-parallel,kvm,nixos-test - -
EOF
  log "registered linux-builder (localhost:$PORT) in $MACHINES"
}

case "${1:-start}" in
  --stop | stop)
    teardown
    exit 0
    ;;
  -h | --help)
    cat >&2 <<'USAGE'
Usage: bootstrap-linux-builder [--stop]

  (no args)  Wire the nix-daemon to a temporary local vz linux-builder and
             launch it (stays attached in this terminal). From another
             terminal: nixos-rebuild switch --flake .#<host>-nixos \
                          --target-host root@nerd-nixos.local
             On exit it ASKS whether to remove the wiring + state dir.
  --stop     Remove the wiring + state dir and kill the builder VM (no prompt).
USAGE
    exit 0
    ;;
esac

mkdir -p "$STATE_DIR" "$WORK_DIR"
wire
trap on_exit EXIT
log "launching the vz linux-builder — KEYS=$KEYS_DIR, images in $WORK_DIR (installs /etc/nix/builder_ed25519), stays attached here"
log "in another terminal, build the sibling:"
log "  nixos-rebuild switch --flake .#<host>-nixos --target-host root@nerd-nixos.local"
log "stop it by interrupting this terminal (you'll be asked to clean up), or: bootstrap-linux-builder --stop"
cd "$WORK_DIR"
env KEYS="$KEYS_DIR" create-builder
