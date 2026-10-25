#!/usr/bin/env bats
# The screen openings are earned: added only for a VIP MagicDNS vouches for, the set rebuilt each run.

bats_require_minimum_version 1.5.0

setup() {
	T=$(mktemp -d)
	export DIG_ANSWERS="$T/answers" NFT_CALLS="$T/nft"
	: >"$NFT_CALLS"
}
teardown() { rm -rf "$T"; }

answers() { printf '%s\n' "$@" >"$DIG_ANSWERS"; }
added() { grep -E '^add element' "$NFT_CALLS" || true; }

@test "both VIPs vouched for: the set is flushed, then holds exactly the two" {
	answers "rdp-a.example.ts.net=100.73.0.1" "rdp-b.example.ts.net=100.77.0.2"
	run --separate-stderr bash "$CHECK"
	[ "$status" -eq 0 ]
	[ "$(head -1 "$NFT_CALLS")" = "flush set inet metalspace-guard offtailnet_screens" ]
	[ "$(added)" = "add element inet metalspace-guard offtailnet_screens { 100.73.0.1 . 5900,100.77.0.2 . 5900 }" ]
}

@test "one VIP re-assigned: only the vouched one is added, and the check fails" {
	answers "rdp-a.example.ts.net=100.73.0.1" "rdp-b.example.ts.net=100.99.9.9"
	run --separate-stderr bash "$CHECK"
	[ "$status" -eq 1 ]
	[ "$(added)" = "add element inet metalspace-guard offtailnet_screens { 100.73.0.1 . 5900 }" ]
	[[ "$stderr" == *"rdp-b.example.ts.net answers '100.99.9.9 ', not exactly the pinned 100.77.0.2"* ]]
}

@test "MagicDNS silent: the set is flushed and left empty, and the check fails" {
	answers
	run --separate-stderr bash "$CHECK"
	[ "$status" -eq 1 ]
	grep -qx "flush set inet metalspace-guard offtailnet_screens" "$NFT_CALLS"
	[ -z "$(added)" ]
}

@test "two A records, a foreign one first and the pinned one last: that opening stays shut, rc 1" {
	answers "rdp-a.example.ts.net=100.73.0.1" "rdp-b.example.ts.net=100.66.6.6" "rdp-b.example.ts.net=100.77.0.2"
	run --separate-stderr bash "$CHECK"
	[ "$status" -eq 1 ]
	[ "$(added)" = "add element inet metalspace-guard offtailnet_screens { 100.73.0.1 . 5900 }" ]
	[[ "$stderr" == *"not exactly the pinned 100.77.0.2"* ]]
}

@test "the set is always flushed before anything is added: a stray element never survives a run" {
	answers "rdp-a.example.ts.net=100.73.0.1" "rdp-b.example.ts.net=100.77.0.2"
	run --separate-stderr bash "$CHECK"
	flush=$(grep -n '^flush set' "$NFT_CALLS" | head -1 | cut -d: -f1)
	add=$(grep -n '^add element' "$NFT_CALLS" | head -1 | cut -d: -f1)
	[ -n "$flush" ] && [ -n "$add" ] && [ "$flush" -lt "$add" ]
}
