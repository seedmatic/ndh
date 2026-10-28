#!/usr/bin/env bats
# ndh::headscaleClient:reregister runs `tailscale up` with the preauth key as a `file:` reference: tailscale reads the
# key itself, so the key never sits in its argv, where `ps` would show it. A stub tailscale records its argv.

setup() {
	stub="$BATS_TEST_TMPDIR/bin"
	mkdir -p "$stub"
	# The interpreter by its path: the darwin sandbox refuses /usr/bin/env.
	cat >"$stub/tailscale" <<EOF
#!$(command -v bash)
printf '%s\\n' "\$*" >>"$BATS_TEST_TMPDIR/tailscale.argv"
EOF
	chmod +x "$stub/tailscale"
	PATH="$stub:$PATH"
	keyFile="$BATS_TEST_TMPDIR/authkey"
	printf 'hskey-auth-SENTINEL-not-a-real-key\n' >"$keyFile"
	# shellcheck source=../lib.sh
	source "$BATS_TEST_DIRNAME/../lib.sh"
}

@test "tailscale up names the key file, never the key" {
	run ndh::headscaleClient:reregister http://headscale.test seat "$keyFile" false false
	[ "$status" -eq 0 ]
	up=$(grep '^up ' "$BATS_TEST_TMPDIR/tailscale.argv")
	[[ "$up" == *"--auth-key=file:$keyFile"* ]]
	run grep -c 'SENTINEL' "$BATS_TEST_TMPDIR/tailscale.argv"
	[ "$output" = 0 ]
}

@test "no --authkey with the key inline is left" {
	run ndh::headscaleClient:reregister http://headscale.test seat "$keyFile" false false
	run grep -c -- '--authkey=' "$BATS_TEST_TMPDIR/tailscale.argv"
	[ "$output" = 0 ]
}
