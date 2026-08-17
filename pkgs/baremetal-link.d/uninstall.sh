#!/usr/bin/env bash
# baremetal-link-uninstall — remove the io.nxmatic.baremetal-link LaunchDaemon
# and undo the en0 alias + routes it installed on the corp Mac.  The mirror of
# install.sh: delivered as text and run as root via `ssh <vz> sudo bash -s`
# (see deploy.sh --uninstall); bash-3.2 compatible, no nix runtime on target.
#
# Build-time tokens (pkgs.replaceVars): interface, vzHostAddress, netCidr,
# tailnetCidr, hostAddress, label, plist, confDir (written WITHOUT at-sigils —
# replaceVars would substitute an at-sigil placeholder here too).
#
# Unlike nnh's netflow-link uninstall (which left its alias to clear on the next
# Wi-Fi re-association), we also delete the two routes we added — they would
# otherwise persist until reboot now that the WatchPaths daemon is gone.
#
# xtrace is the narration; `: "…"` marks milestones.
set -euxo pipefail

PATH="/bin:/usr/bin:/sbin:/usr/sbin:$PATH"

[[ "$(id -u)" -eq 0 ]] || {
  : "[baremetal-link] must run as root (via: ssh <vz-host> sudo bash -s)"
  exit 1
}

interface="@interface@"
vz_address="@vzHostAddress@"
net_cidr="@netCidr@"
tailnet_cidr="@tailnetCidr@"
via="@hostAddress@"
label="@label@"
plist="@plist@"
conf_dir="@confDir@"

: "[baremetal-link] unloading + removing ${label}"
launchctl bootout system "$plist" 2>/dev/null || true
rm -f "$plist"
rm -rf "$conf_dir"

: "[baremetal-link] deleting routes + alias added by the daemon"
for net in "$net_cidr" "$tailnet_cidr"; do
  /sbin/route -n delete -net "$net" "$via" 2>/dev/null || true
done
/sbin/ifconfig "$interface" -alias "$vz_address" 2>/dev/null || true

: "[baremetal-link] ${label} removed (${vz_address} alias + routes via ${via} torn down)"
