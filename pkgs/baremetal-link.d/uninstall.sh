#!/usr/bin/env bash
# baremetal-link-uninstall — remove the io.seedmatic.baremetal-link LaunchDaemon
# and undo the interface alias + routes it installed on the vz-host.  The mirror of
# install.sh: delivered as text and run as root via `ssh <vz> sudo bash -s`
# (see deploy.sh --uninstall); bash-3.2 compatible, no nix runtime on target.
#
# Build-time tokens (pkgs.replaceVars): bridgeService, vzHostAddress, linkRoutes,
# vzHostKind, hostAddress, domain, label, plist, confDir (written WITHOUT
# at-sigils — replaceVars would substitute an at-sigil placeholder here too).
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

bridge_service="@bridgeService@"
vz_address="@vzHostAddress@"
link_routes="@linkRoutes@"
vz_host_kind="@vzHostKind@"
via="@hostAddress@"
domain="@domain@"
label="@label@"
plist="@plist@"
conf_dir="@confDir@"

: "[baremetal-link] unloading + removing ${label}"
launchctl bootout system "$plist" 2>/dev/null || true
rm -f "$plist"
rm -rf "$conf_dir"

: "[baremetal-link] deleting routes + alias added by the daemon"
for net in ${link_routes}; do
  /sbin/route -n delete -net "$net" "$via" 2>/dev/null || true
done
# Same service→device resolution install's link-up.sh does, so the teardown removes the
# alias from whatever device the service currently maps to (see install.sh).
iface="$(/usr/sbin/networksetup -listnetworkserviceorder \
  | /usr/bin/sed -n "s/^(Hardware Port: ${bridge_service}, Device: \(.*\))\$/\1/p" \
  | /usr/bin/head -1)"
[[ -n "$iface" ]] && /sbin/ifconfig "$iface" -alias "$vz_address" 2>/dev/null || true

: "[baremetal-link] removing scoped resolver /etc/resolver/${domain}"
# Only ours to remove on a foreign vz-host; on a nix-managed one the file belongs to
# modules/darwin/baremetal-resolvers.nix (see install.sh).
if [[ "$vz_host_kind" == "foreign" ]]; then
  rm -f "/etc/resolver/${domain}"
  dscacheutil -flushcache 2>/dev/null || true
  killall -HUP mDNSResponder 2>/dev/null || true
fi

: "[baremetal-link] ${label} removed (${vz_address} alias + routes via ${via} + resolver .${domain} torn down)"
