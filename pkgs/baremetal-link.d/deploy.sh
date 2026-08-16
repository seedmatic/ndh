#!/usr/bin/env bash
# baremetal-link-deploy — install/refresh the baremetal-link LaunchDaemon on the
# corporate bare-metal Mac.  The daemon uses only macOS system tools (ifconfig,
# route, launchctl) and is bash-3.2 compatible, so NO nix runtime is needed on
# the target: we deliver the rendered install script as TEXT over ssh and run it
# with sudo.  That keeps the deploy runnable from anywhere `ssh <vz-host>`
# resolves — the operator's Mac or nikopol-nixos's activation oneshot (which is
# aarch64-linux and could not hold a darwin closure anyway).
#
# Build-time tokens (pkgs.replaceVars): @installScript@ / @uninstallScript@
# (rendered script store paths) @vzHost@ (default ssh target) @bootstrapHost@
# (first-run fallback).
#
# Usage: <host>-baremetal-link-deploy [vz-host] [--uninstall]
#
# xtrace is the narration (set -x traces the reachability probe + the ssh
# pipe); `: "…"` marks the milestones.
set -euxo pipefail

vz_host="@vzHost@"
if (($# > 0)) && [[ "$1" != --* ]]; then
  vz_host="$1"
  shift
fi

# --uninstall selects the teardown script; default is install.  Both are
# rendered from the same catalog values, so an uninstall undoes exactly what
# the matching install put in place.
script="@installScript@"
action="install"
case "${1:-}" in
  --uninstall)
    script="@uninstallScript@"
    action="uninstall"
    shift
    ;;
  --install)
    shift
    ;;
esac

# Bootstrap: on the very first run vz.<host> does not yet resolve to its .253
# alias (this daemon is what sets it), so fall back to the mDNS name if the
# primary target is unreachable.  Once the alias is up, vz.<host> resolves and
# is used directly.
target="$vz_host"
if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$vz_host" true 2>/dev/null; then
  : "[baremetal-link-deploy] ${vz_host} unreachable — falling back to @bootstrapHost@"
  target="@bootstrapHost@"
fi

: "[baremetal-link-deploy] ${action} on ${target} (sudo, from stdin)"
# Pipe the chosen rendered script to the target and run it as root.  Idempotent
# on the target (install: bootout -> bootstrap); sudo is NOPASSWD on the vz host.
exec ssh "$target" sudo /bin/bash -s <"$script"
