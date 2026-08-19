#!/usr/bin/env bash
# baremetal-link — install the io.seedmatic.baremetal-link LaunchDaemon on a
# CORPORATE bare-metal Mac (vzhost.<host>) that cannot join the tailnet.  It aliases
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
# Build-time tokens (pkgs.replaceVars): interface, vzHostAddress, linkPrefix,
# netCidr, tailnetCidr, hostAddress, domain, netGateway, label, plist, confDir,
# log (written WITHOUT their at-sigils — replaceVars would substitute an at-sigil
# placeholder here too).
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
domain="@domain@"
net_gateway="@netGateway@"
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
#
# Then, when the host's uplink actually changes (a new DHCP lease appears), it
# nudges the Incus-host guest to re-acquire its own lan-br lease over the /30 —
# so a single network switch auto-recovers the whole stack (host alias/routes +
# guest lease + its tailscale, which self-heals once the guest network is fresh).
# The WatchPaths bursts double as the retry loop; a lease-change guard fires the
# nudge exactly once (see below).
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

# Once ${interface} holds a REAL DHCP lease on the (possibly new) network AND it
# changed since last run, nudge the Incus-host guest to re-acquire ITS own lan-br
# lease over the /30 (host-local, reached via \$via). The WatchPaths bursts ARE the
# retry loop, so no polling: no lease yet -> skip; lease appeared/changed -> nudge
# once; same lease -> skip (dedup). ipconfig getifaddr returns empty for a missing
# or self-assigned (169.254) address. Non-blocking (BatchMode + ConnectTimeout +
# || true): a missing key or an unreachable guest never stalls the re-apply above.
lease="\$(/usr/sbin/ipconfig getifaddr ${interface} 2>/dev/null || true)"
if [ -n "\$lease" ] && [ "\$lease" != "\$(cat ${conf_dir}/.uplink-lease 2>/dev/null)" ]; then
  # Nudge first; record the lease ONLY on success, so a failed or transiently
  # unreachable guest (e.g. host-key not yet accepted, guest still booting) is
  # retried on the next WatchPaths fire instead of being silently marked done.
  if /usr/bin/ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \\
       root@${via} 'networkctl reconfigure lan-br' 2>/dev/null; then
    echo "\$lease" > ${conf_dir}/.uplink-lease
  fi
fi
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

# Scoped macOS resolver for the .${domain} baremetal DNS zone.  This corp Mac
# does NOT run a nix-darwin config, so modules/darwin/baremetal-resolvers.nix
# never lands here — the daemon installer owns the same /etc/resolver/<domain>
# file instead.  macOS routes a split-horizon domain ONLY via a scoped resolver
# file (the flat global list would take a public NXDOMAIN as definitive), so we
# point .${domain} straight at its segment's Incus dnsmasq (netGateway),
# reachable over the /25 route the alias just installed.  Static file (survives
# Wi-Fi re-association), so it lives here rather than in link-up.sh.
: "[baremetal-link] scoping resolver: .${domain} -> ${net_gateway}"
mkdir -p /etc/resolver
cat >"/etc/resolver/${domain}" <<RESOLVER
# Split-DNS for the ${domain} baremetal segment (vzhost.${domain} + instances).
# Resolves via the segment's Incus dnsmasq, reached over the advertised subnet route.
nameserver ${net_gateway}
RESOLVER
chown root:wheel "/etc/resolver/${domain}"
chmod 0644 "/etc/resolver/${domain}"
dscacheutil -flushcache 2>/dev/null || true
killall -HUP mDNSResponder 2>/dev/null || true

: "[baremetal-link] ${label} up: ${vz_address}/${link_prefix} on ${interface}; routes ${net_cidr} + ${tailnet_cidr} via ${via}; resolver .${domain} -> ${net_gateway} (log ${log})"
