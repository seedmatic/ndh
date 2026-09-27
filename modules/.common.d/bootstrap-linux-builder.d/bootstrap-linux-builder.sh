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
# What $MACHINES WAS before we wired: `symlink <target>`, `file`, or `absent`.
# Recording the KIND — not just the contents — is what lets teardown put the
# nix-darwin-managed symlink back. See the note in wire().
MACHINES_STATE=/etc/nix/.machines.pre-bootstrap-builder.kind
KNOWN_HOSTS=/var/root/.ssh/known_hosts.linux-builder
PORT=31022

log() { printf '[bootstrap-linux-builder] %s\n' "$*" >&2; }

teardown() {
  log "removing temporary builder wiring"
  sudo rm -f "$SSH_CONF"
  # Restore the KIND, not the bytes. Putting a regular file back where nix-darwin
  # keeps a symlink shadows the declarative wiring: activation then refuses to
  # clobber it (it moves it aside as machines.before-nix-darwin) and `builders`
  # keeps serving the stale contents. Measured 2026-09-27 — that is how a
  # `builder@linux-builder` entry outlived its VM and blocked a re-materialisation.
  machines_kind=""
  if sudo test -f "$MACHINES_STATE"; then
    machines_kind="$(sudo cat "$MACHINES_STATE")"
  fi
  case "${machines_kind%% *}" in
    symlink)
      sudo ln -sfn "${machines_kind#symlink }" "$MACHINES"
      log "restored $MACHINES -> ${machines_kind#symlink } (nix-darwin-managed)"
      ;;
    file)
      sudo mv -f "$MACHINES_BAK" "$MACHINES"
      log "restored $MACHINES from backup (it was an unmanaged file)"
      ;;
    *)
      # `absent`, or no marker at all — a pre-fix run, or wire() never got there.
      sudo rm -f "$MACHINES"
      log "removed $MACHINES (nothing recorded to restore)"
      log "⚠️  if this host is nix-darwin-managed, run darwin-rebuild switch to relink it"
      ;;
  esac
  sudo rm -f "$MACHINES_STATE"
  if pkill -f 'bin/vzvm' 2>/dev/null; then
    log "stopped the vz builder VM"
  fi
  rm -rf "$STATE_DIR"
  log "removed state dir $STATE_DIR"
  log "done — flip ndh.hostBuilder to steady + darwin-rebuild switch for the durable wiring"
}

# EXIT trap: the builder just stopped (Ctrl-C, poweroff, crash). Default to
# TEARING DOWN, and make keeping it the deliberate answer.
#
# It used to default the other way, so an unanswered prompt left the wiring
# behind — and that wiring is a file that SHADOWS nix-darwin's managed symlink,
# so it silently defeats every later `darwin-rebuild switch`. Measured
# 2026-09-27: a `builder@linux-builder` entry pointing at a stopped VM survived
# the builder, two activations did not dislodge it, and it blocked a
# re-materialisation until it was found by hand. An interrupted build in another
# terminal is the lesser harm — it is visible, and re-runnable.
on_exit() {
  printf '\n' >&2
  local ans=""
  if [ -e /dev/tty ]; then
    read -r -p "[bootstrap-linux-builder] builder stopped — KEEP the wiring? (a build may still be running elsewhere) [y/N] " ans </dev/tty >/dev/tty 2>&1 || ans=""
  fi
  case "$ans" in
    [yY] | [yY][eE][sS])
      log "wiring KEPT — it shadows the nix-darwin-managed $MACHINES, so run"
      log "  bootstrap-linux-builder --stop"
      log "before the next darwin-rebuild, or the stale builder entry will outlive this VM"
      ;;
    *) teardown ;;
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
  # Record WHAT $MACHINES was, so teardown can put the same KIND back. On a
  # nix-darwin host it is a symlink into /etc/static, and `test -f` FOLLOWS the
  # link — so the old code copied the link's CONTENTS and later restored them as a
  # regular file, permanently shadowing the declarative wiring. Record the link
  # itself instead.
  if ! sudo test -f "$MACHINES_STATE"; then
    if sudo test -L "$MACHINES"; then
      printf 'symlink %s\n' "$(sudo readlink "$MACHINES")" | sudo tee "$MACHINES_STATE" >/dev/null
      log "recorded $MACHINES as a managed symlink -> $(sudo readlink "$MACHINES")"
    elif sudo test -f "$MACHINES"; then
      printf 'file\n' | sudo tee "$MACHINES_STATE" >/dev/null
      sudo cp "$MACHINES" "$MACHINES_BAK"
      log "backed up existing (unmanaged) $MACHINES -> $MACHINES_BAK"
    else
      printf 'absent\n' | sudo tee "$MACHINES_STATE" >/dev/null
    fi
  fi
  # Unlink first: writing THROUGH the managed symlink would target a read-only
  # store path.
  sudo rm -f "$MACHINES"
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
             On exit it tears the wiring down, asking first whether to KEEP it.
  --stop     Restore the wiring to what it was, remove the state dir, kill the
             builder VM (no prompt). On a nix-darwin host that means putting the
             managed /etc/nix/machines symlink back — a regular file left there
             shadows it and defeats every later darwin-rebuild switch.
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
