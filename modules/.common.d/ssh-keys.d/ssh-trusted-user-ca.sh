#!/usr/bin/env -S bash -euo pipefail
# @codebase
# Rebuild sshd's TrustedUserCAKeys aggregate, <keysDir>/trusted-user-ca.pub, from every authority public in
# <keysDir> (`*-ca.pub`), on every activation so a stale authority cannot linger. darwin and NixOS run this one
# script.
#
# It trusts the FILES it finds: which authorities become a `-ca.pub` at all is the extractor's split expression
# (only `usage: [ssh-authority]`), and ssh-keys.d/tests/trust-by-usage.bats checks the two together.

# shellcheck disable=SC1091
source @nixBashTrampoline@

main() {
	local keysDir="${1:?keys directory required}"
	local aggregate="${keysDir}/trusted-user-ca.pub"
	local ca

	[[ -d $keysDir ]] || {
		echo "no keys directory: ${keysDir}" >&2
		return 1
	}
	: >"$aggregate"
	for ca in "$keysDir"/*-ca.pub; do
		[[ -f $ca ]] || continue
		[[ ${ca##*/} != trusted-user-ca.pub ]] || continue
		cat "$ca" >>"$aggregate"
		printf '\n' >>"$aggregate"
	done
	chmod 644 "$aggregate"
}

ndh::logger:command:run "@loggerTag@" main "$@"
