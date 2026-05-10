#!/usr/bin/env -S bash -euo pipefail
source @nixBashTrampoline@

main() {
	# Aggregate every CA public from the runtime user keys directory into
	# the single file sshd consumes via TrustedUserCAKeys. No intermediate
	# per-CA copies under @keysDir@ — the source directory is the one place
	# CA material is curated, and trusted-user-ca.pub is the one place sshd
	# reads it.
	install -d -m 755 "@keysDir@"

	: > "@keysDir@/trusted-user-ca.pub"
	for ca in "@hostKeysDir@"/*-ca.pub; do
		[ -f "$ca" ] || continue
		cat "$ca" >> "@keysDir@/trusted-user-ca.pub"
		printf "\n" >> "@keysDir@/trusted-user-ca.pub"
	done
	chmod 644 "@keysDir@/trusted-user-ca.pub"

	# Drop the per-CA copies created by earlier activations so /etc/ssh/keys.d/
	# carries only the aggregate going forward. Find avoids matching
	# trusted-user-ca.pub itself.
	find "@keysDir@" -maxdepth 1 -type f -name '*-ca.pub' \
		! -name 'trusted-user-ca.pub' -delete 2>/dev/null || true
}

ndh::logger:command:run "@loggerTag@" main "$@"
