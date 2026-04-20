#!/usr/bin/env -S bash -euo pipefail
source @nixBashTrampoline@

main() {
	# Install system CA public keys from runtime user keys directory.
	install -d -m 755 "@keysDir@"
	for ca in "@hostKeysDir@"/*-ca.pub; do
		[ -f "$ca" ] || continue
		install -m 644 "$ca" "@keysDir@/$(basename "$ca")"
	done

	: > "@keysDir@/trusted-user-ca.pub"
	for ca in "@keysDir@/"*-ca.pub; do
		[ -f "$ca" ] || continue
		basename "$ca" | grep -q '^trusted-user-ca\.pub$' && continue
		cat "$ca" >> "@keysDir@/trusted-user-ca.pub"
		printf "\n" >> "@keysDir@/trusted-user-ca.pub"
	done
	chmod 644 "@keysDir@/trusted-user-ca.pub"
}

ndh::logger:command:run "@loggerTag@" main "$@"
