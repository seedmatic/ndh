#!/usr/bin/env bash
# baremetal-link — install the io.nxmatic.baremetal-link LaunchDaemon on a
# CORPORATE bare-metal Mac (vz.<host>) that cannot join the tailnet.  It aliases
# the Wi-Fi interface with this host's static /30 endpoint and installs the two
# routes that make the Incus instance segment and the tailnet reachable through
# the Incus host (the subnet router) — with NO NAT, so source IPs are preserved.
# macOS drops interface aliases on Wi-Fi re-association, so a WatchPaths
# LaunchDaemon re-applies the alias + routes at load and on every re-assoc.
#
# Generalised from nnh's netflow-link (which carried the probe's own /30 alias):
# ndh owns the link between a bare-metal and its network; nnh owns the probe +
# collector.  All addresses are rendered from catalog.netplan.baremetal.<host>
# at build time (@vzHostAddress@ etc.) — never hand-typed here.
#
# Build-time tokens (pkgs.replaceVars): @interface@ @vzHostAddress@ @linkPrefix@
# @netCidr@ @tailnetCidr@ @hostAddress@ @label@ @plist@ @confDir@ @log@.
# Delivered as text and run as root via `ssh <vz> sudo bash -s` (see deploy.sh);
# no nix runtime is required on the target, and it is bash-3.2 compatible.
#
# xtrace is the narration: `set -x` traces every ifconfig/route/launchctl call,
# so there are no echo lines — only `: "…"` markers for human-level milestones.
set -euxo pipefail

# launchctl, ifconfig and route live in the macOS system paths, outside the
# writeShellApplication curated PATH.
PATH="/bin:/usr/bin:/sbin:/usr/sbin:$PATH"

[[ "$(id -u)" -eq 0 ]] || {
  : "[baremetal-link] must run as root (via: ssh <vz-host> sudo bash -s)"
  exit 1
}

interface="@interface@"
vz_address="@vzHostAddress@"
link_prefix="@linkPrefix@"
net_cidr="@netCidr@"
tailnet_cidr="@tailnetCidr@"
via="@hostAddress@"
label="@label@"
plist="@plist@"
conf_dir="@confDir@"
log="@log@"

# Dotted netmask from the /30 prefix, computed here so the deployed link-up.sh
# carries a plain 255.255.255.252 (macOS ifconfig wants dotted, not CIDR).
mask=$((0xffffffff ^ ((1 << (32 - link_prefix)) - 1)))
link_netmask="$(((mask >> 24) & 255)).$(((mask >> 16) & 255)).$(((mask >> 8) & 255)).$((mask & 255))"

: "[baremetal-link] rendering link-up.sh + ${label} plist under ${conf_dir}"
mkdir -p "$conf_dir"

# The re-apply script the LaunchDaemon runs at load and on every Wi-Fi
# re-association.  Idempotent: alias only if absent; `route add || route change`
# so a stale gateway is corrected.  net_cidr reaches the Incus instances and
# tailnet_cidr is the no-NAT tailnet return path — both through $via (the Incus
# host / subnet router, on-link via the /30 alias).  It runs `set -x` too, so
# its trace lands in @log@.  The heredoc is UNQUOTED so the rendered values
# interpolate now; the deployed loop variable stays literal (\$net).
cat >"$conf_dir/link-up.sh" <<LINK
#!/bin/sh
# rendered by baremetal-link-install — re-applies the static /30 alias + routes.
set -x
PATH="/bin:/usr/bin:/sbin:/usr/sbin"
/sbin/ifconfig ${interface} 2>/dev/null | /usr/bin/grep -q "inet ${vz_address} " \\
  || /sbin/ifconfig ${interface} inet ${vz_address} netmask ${link_netmask} alias
for net in ${net_cidr} ${tailnet_cidr}; do
  /sbin/route -n add -net "\$net" ${via} 2>/dev/null \\
    || /sbin/route -n change -net "\$net" ${via} 2>/dev/null || true
done
LINK
chown root:wheel "$conf_dir/link-up.sh"
chmod 0755 "$conf_dir/link-up.sh"

cat >"$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string>
    <string>${conf_dir}/link-up.sh</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>WatchPaths</key>
  <array>
    <string>/Library/Preferences/SystemConfiguration</string>
  </array>
  <key>StandardOutPath</key><string>${log}</string>
  <key>StandardErrorPath</key><string>${log}</string>
</dict>
</plist>
PLIST
chown root:wheel "$plist"
chmod 0644 "$plist"

: "[baremetal-link] (re)loading ${label}"
# Idempotent (re)load: unconditional bootout before bootstrap (modern API).
launchctl bootout system "$plist" 2>/dev/null || true
launchctl bootstrap system "$plist"
launchctl enable "system/${label}"

: "[baremetal-link] ${label} up: ${vz_address}/${link_prefix} on ${interface}; routes ${net_cidr} + ${tailnet_cidr} via ${via} (log ${log})"
