#!/usr/bin/env -S bash -euo pipefail
# Resolve the bare-metal MacBook Pro's current IPv4 from the local
# ARP cache, by matching its stable MAC address.
#
# The bare metal that hosts this Tart VM keeps "Private Wi-Fi
# address" set to Off, so its `en0` MAC is the same on every Wi-Fi
# network — at home (192.168.1.x bbox lease), at work (10.0.0.x
# corp DHCP), at a hotspot (whatever Android hands out).  Whichever
# segment the VM and bare metal are bridged onto, an `arp -an`
# lookup keyed on the MAC yields the bare metal's current IP.
#
# Used as the `ProxyCommand` resolver behind the `vz.nikopol`
# SSH alias on this VM (and indirectly on bioskop, which lands in
# this VM via `ProxyJump=nikopol` and then re-uses the same alias).
#
# Cache cold-start: macOS ages ARP entries out at ~20 minutes of
# idle.  If the bare metal hasn't talked to the VM recently, the
# entry is missing.  The script emits a one-shot `ping -c 1` to the
# default-route broadcast first to provoke an ARP exchange, then
# retries the lookup.
#
# This script is invoked from SSH's `ProxyCommand` substitution and
# its stdout MUST be a clean IPv4 literal (no logger framing, no
# diagnostics).  Diagnostics go to stderr only, where SSH ignores
# them.  The trampoline is intentionally NOT sourced here — the
# logger wrapper would muddy stdout.
#
# Tokens substituted at build time by pkgs.replaceVars:
#   @bareMetalMac@ — the bare metal's stable hardware MAC.

main() {
	local mac="@bareMetalMac@"

	local ip
	ip="$(ndh::vzHostResolver:lookup "$mac")"
	if [[ -z "$ip" ]]; then
		# Cache miss: provoke ARP exchange via broadcast ping, retry.
		# Quiet the ping output; we only care about the side effect of
		# populating the ARP cache.  `-c 1 -W 1` caps wall-clock at ~1s.
		ping -c 1 -W 1 -b "$(ndh::vzHostResolver:broadcastAddr)" >/dev/null 2>&1 || true
		sleep 1
		ip="$(ndh::vzHostResolver:lookup "$mac")"
	fi

	if [[ -z "$ip" ]]; then
		echo "vz-host resolver: bare metal (mac=$mac) not found in local ARP cache after broadcast ping" >&2
		echo "vz-host resolver: ensure the bare metal is on the same Wi-Fi network as this VM" >&2
		return 1
	fi

	printf '%s\n' "$ip"
}

# Inspect the local ARP cache for a row matching the requested MAC,
# return the dotted-quad IP without parens.  Empty stdout on miss.
#
# `arp -an` rows look like:
#   ? (10.0.0.27) at 52:2d:10:fa:5a:1c on en0 ifscope [ethernet]
# Field 2 is the parenthesised IP, field 4 is the MAC.  macOS's
# `arp` does NOT strip leading zeros (verified empirically on
# Darwin 25.x), so a literal lowercase-hex compare suffices —
# previous iterations of this resolver had a normalisation pass
# that introduced its own off-by-one bug.
ndh::vzHostResolver:lookup() {
	local mac="${1,,}"
	arp -an 2>/dev/null | awk -v target="$mac" '
		{
			gsub(/[()]/, "", $2)
			if (tolower($4) == target) {
				print $2
				exit
			}
		}
	'
}

# Compute the broadcast address for en0's primary IPv4.  Used to
# warm the ARP cache when the bare metal hasn't been talked to
# recently.  Falls back to 255.255.255.255 if `en0` isn't IPv4.
ndh::vzHostResolver:broadcastAddr() {
	local bcast
	bcast="$(ifconfig en0 2>/dev/null \
		| awk '/inet [0-9]/{ for (i = 1; i <= NF; i++) if ($i == "broadcast") { print $(i + 1); exit } }')"
	printf '%s\n' "${bcast:-255.255.255.255}"
}

main "$@"
