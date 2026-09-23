#!/usr/bin/env bash
# baremetal-link — install the io.seedmatic.baremetal-link LaunchDaemon on a
# bare-metal Mac (vzhost.<host>).  It aliases the NIC the vz guest is BRIDGED onto
# (the rendered `bridgeService` — Wi-Fi on the corp MacBook, Thunderbolt Ethernet on the Mini)
# with this host's static /30 endpoint, and installs the `linkRoutes` spans that make
# the Incus instance segment (and, for a foreign vz-host, the tailnet) reachable through
# the Incus host (the subnet router) — with NO NAT, so source IPs are preserved.  That
# NIC is the right one because the /30's far end is the guest's lan-br: they share an L2.
# macOS drops interface aliases when the link re-associates, so a WatchPaths
# LaunchDaemon re-applies the alias + routes at load and on every re-assoc.
#
# Generalised from nnh's netflow-link (which carried the probe's own /30 alias):
# ndh owns the link between a bare-metal and its network; nnh owns the probe +
# collector.  All addresses are rendered from catalog.netplan.baremetal.<host>
# at build time (@vzHostAddress@ etc.) — never hand-typed here.
#
# Build-time tokens (pkgs.replaceVars): bridgeService, vzHostAddress, linkPrefix,
# linkRoutes, hostAddress, domain, netGateway, label, plist, confDir,
# log (written WITHOUT their at-sigils — replaceVars would substitute an at-sigil
# placeholder here too).
# TWO deliveries, one artifact.  A `foreign` vz-host gets this rendered text piped over
# ssh and run as root (see deploy.sh) — no nix runtime on the target, bash-3.2 compatible.
# A `nix-managed` vz-host runs this very script from its own darwin activation instead
# (modules/darwin/baremetal-link.nix), which is why the two sections nix-darwin already
# owns there — /etc/resolver/<domain> and the guest nudge — are gated on vz_host_kind.
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

bridge_service="@bridgeService@"
vz_address="@vzHostAddress@"
link_prefix="@linkPrefix@"
link_routes="@linkRoutes@"
vz_host_kind="@vzHostKind@"
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

# RETRACT the plan this daemon last applied, before writing the new one. Everything below
# only ADDS — an alias is set if absent, a route is (re)installed — so without this a
# renumbering leaves the previous alias and the previous routes in place beside the new
# ones. Measured after nikopol moved slices: the Mac carried both 172.16.6.253 and
# 172.16.24.2, a dead 172.16.6.0/25, and — the one that actually hurt — its tailnet route
# still aimed at the retired /30 gateway, leaving it with NO path to the tailnet.
#
# The retraction reads a state file the applier wrote, so it removes EXACTLY what this
# daemon put there and nothing else. That matters on a corp-managed Mac, where 172.16/12 is
# not necessarily ours alone: scoping by prefix would have risked a VPN's addresses.
applied="$conf_dir/.applied"
if [[ -r "$applied" ]]; then
  : "[baremetal-link] retracting the previously applied plan"
  prev_iface="" prev_address="" prev_routes=""
  # shellcheck source=/dev/null
  . "$applied"
  for net in ${prev_routes}; do
    /sbin/route -n delete -net "$net" 2>/dev/null || true
  done
  if [[ -n "$prev_iface" && -n "$prev_address" ]]; then
    /sbin/ifconfig "$prev_iface" -alias "$prev_address" 2>/dev/null || true
  fi
fi

# The re-apply script the LaunchDaemon runs at load and on every Wi-Fi
# re-association.  Idempotent: alias only if absent; `route add || route change`
# so a stale gateway is corrected.  link_routes is the list of spans to reach over
# this /30 (the segment always; the tailnet only for a foreign vz-host that has no
# tailnet interface of its own — see the flake's baremetalLinkVars), all via $via (the Incus
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

# Resolve the SERVICE name to its current BSD device, here rather than at install
# time: enX numbering shifts when adapters are added or removed, and this daemon
# fires on exactly that event (WatchPaths on SystemConfiguration). Resolving per run
# is what makes the link survive a renumbering without a redeploy. Empty result =
# the adapter is absent right now (unplugged dock); skip the alias and let the next
# burst retry rather than failing the daemon.
iface="\$(/usr/sbin/networksetup -listnetworkserviceorder \\
  | /usr/bin/sed -n 's/^(Hardware Port: ${bridge_service}, Device: \\(.*\\))\$/\\1/p' \\
  | /usr/bin/head -1)"
if [ -z "\$iface" ]; then
  : "[baremetal-link] service '${bridge_service}' has no device right now — skipping"
  exit 0
fi

/sbin/ifconfig "\$iface" 2>/dev/null | /usr/bin/grep -q "inet ${vz_address} " \\
  || /sbin/ifconfig "\$iface" inet ${vz_address} netmask ${link_netmask} alias
# delete-then-add, not add-or-change: when only the GATEWAY moves, route change is
# unreliable on macOS and its failure was swallowed by the trailing or-true — which is how
# the tailnet route stayed pointed at a retired gateway through a renumbering.
# (No backticks in this heredoc: it is UNQUOTED, so they would be command substitution.)
for net in ${link_routes}; do
  /sbin/route -n delete -net "\$net" 2>/dev/null || true
  /sbin/route -n add -net "\$net" ${via} 2>/dev/null || true
done

# Record what was just applied, so the next install can retract exactly this and no more.
cat > ${conf_dir}/.applied <<APPLIED
prev_iface="\$iface"
prev_address="${vz_address}"
prev_routes="${link_routes}"
APPLIED
LINK

# The guest-reconfigure nudge, appended ONLY for a foreign vz-host.  It exists because a
# ROAMING corp Mac is the only party that can tell its guest the network moved; it also
# needs /var/root/.ssh/vz-nudge, which the ssh deploy ships and a nix-managed host has no
# reason to hold.  Emitting it there would retry a doomed ssh on every WatchPaths burst
# (the lease marker is only written on success), so the guard is correctness, not taste.
if [[ "$vz_host_kind" == "foreign" ]]; then
  cat >>"$conf_dir/link-up.sh" <<NUDGE

# Once the adapter holds a REAL DHCP lease on the (possibly new) network AND it
# changed since last run, nudge the Incus-host guest to re-acquire ITS own lan-br
# lease over the /30 (host-local, reached via \$via). The WatchPaths bursts ARE the
# retry loop, so no polling: no lease yet -> skip; lease appeared/changed -> nudge
# once; same lease -> skip (dedup). ipconfig getifaddr returns empty for a missing
# or self-assigned (169.254) address. Non-blocking (BatchMode + ConnectTimeout +
# || true): a missing key or an unreachable guest never stalls the re-apply above.
lease="\$(/usr/sbin/ipconfig getifaddr "\$iface" 2>/dev/null || true)"
if [ -n "\$lease" ] && [ "\$lease" != "\$(cat ${conf_dir}/.uplink-lease 2>/dev/null)" ]; then
  # Nudge first; record the lease ONLY on success, so a failed or transiently
  # unreachable guest (e.g. key not yet shipped, guest still booting) is retried
  # on the next WatchPaths fire instead of being silently marked done.
  # Auth = the vz-nudge CA-signed identity shipped here by the deploy (private +
  # user cert); IdentitiesOnly pins it (no agent/other keys). Its cert principal
  # (rdp-host) grants root on the guest via TrustedUserCAKeys — rotates freely.
  if /usr/bin/ssh -i /var/root/.ssh/vz-nudge -o CertificateFile=/var/root/.ssh/vz-nudge-cert.pub \\
       -o IdentitiesOnly=yes -o UserKnownHostsFile=/var/root/.ssh/known_hosts \\
       -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \\
       root@${via} 'networkctl reconfigure lan-br' 2>/dev/null; then
    echo "\$lease" > ${conf_dir}/.uplink-lease
  fi
fi
NUDGE
fi
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

# Scoped macOS resolver for the .${domain} baremetal DNS zone — ONLY for a foreign
# vz-host.  macOS routes a split-horizon domain only via a scoped resolver file (the
# flat global list would take a public NXDOMAIN as definitive), so .${domain} has to
# point straight at its segment's Incus dnsmasq (netGateway), reachable over the route
# the alias just installed.  A foreign vz-host runs no nix-darwin config, so
# modules/darwin/baremetal-resolvers.nix never lands there and this installer owns the
# file.  On a nix-managed vz-host that module DOES own it (via environment.etc), and two
# owners writing one path would fight at every activation — so we leave it alone.
if [[ "$vz_host_kind" == "foreign" ]]; then
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
else
  : "[baremetal-link] resolver .${domain} is owned by baremetal-resolvers.nix here — skipped"
fi

: "[baremetal-link] ${label} up: ${vz_address}/${link_prefix} on '${bridge_service}'; routes ${link_routes} via ${via}; resolver .${domain} -> ${net_gateway} (log ${log})"
