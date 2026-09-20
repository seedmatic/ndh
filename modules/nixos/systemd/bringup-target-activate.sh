#!/usr/bin/env -S bash -euo pipefail
# shellcheck source=/dev/null
source "@nixBashTrampoline@"

# Hand the node over from the bringup generation to the system it was
# provisioned for, on first boot, without an operator and without a network.
#
# The target is READ FROM A FILE and never baked into this script.  That is the
# load-bearing decision: baking it would make the bringup toplevel name the
# runtime toplevel, nix records a reference for every store path it finds in an
# output, and the bringup closure would swallow the runtime one — collapsing the
# EROFS layer stack back into a single layer.  The nested-VM installer writes the
# file onto the target root instead, where no closure of ours can see it.
#
# Nothing is copied and nothing is built here.  The target's closure is already
# in the store: it arrived as an EROFS layer and the installer replayed the union
# closure into the Nix database.  Measured on nikopol-nixos on 2026-09-20, doing
# this by hand took 0.804 s and wrote a single 21 KB path.

main() {
	local target_file="@targetFile@"
	local attempt_file="@attemptFile@"
	local target=""
	local current=""

	if [[ ! -r "$target_file" ]]; then
		echo "[bringup-target-activate] no target declared at ${target_file}; staying on the bringup" >&2
		return 0
	fi

	target="$(<"$target_file")"
	if [[ -z "$target" ]]; then
		echo "[bringup-target-activate][ERROR] target file is present but empty: ${target_file}" >&2
		return 1
	fi

	current="$(readlink -f /run/current-system 2>/dev/null || true)"
	if [[ "$current" == "$target" ]]; then
		echo "[bringup-target-activate] already running the target; nothing to do: ${target}" >&2
		return 0
	fi

	if [[ ! -x "${target}/bin/switch-to-configuration" ]]; then
		echo "[bringup-target-activate][ERROR] the target is not in this store: ${target}" >&2
		echo "[bringup-target-activate][ERROR] the EROFS layer carrying it is missing or mounted under another label" >&2
		return 1
	fi

	# One attempt, ever.  Coming back here still on the bringup means the
	# handover did not take; retrying would reboot-loop the node, which is far
	# worse than stopping on a bringup that still answers SSH.
	if [[ -e "$attempt_file" ]]; then
		echo "[bringup-target-activate][ERROR] handover already attempted, and this is still the bringup" >&2
		echo "[bringup-target-activate][ERROR] refusing to retry; investigate, then remove ${attempt_file}" >&2
		return 1
	fi

	echo "[bringup-target-activate] handing over to ${target}" >&2
	nix-env --profile /nix/var/nix/profiles/system --set "$target"

	# `boot`, not `switch`: the target has never been activated on this node, so
	# an online switch runs its activation scripts before the boot units have
	# seeded the NDH bringup-runtime profile, and the age-key enforce fails.
	# `boot` only installs the bootloader entry and moves the profile; the reboot
	# then brings the target up in the right order.
	"${target}/bin/switch-to-configuration" boot

	install -d -m 0755 "$(dirname "$attempt_file")"
	printf '%s\n' "$target" >"$attempt_file"

	echo "[bringup-target-activate] rebooting into the target generation" >&2
	# --no-block: this unit is part of the transaction systemd would have to stop
	# to reboot, so a blocking call deadlocks against itself.
	systemctl --no-block reboot
}

ndh::logger:command:run "@loggerTag@" main "$@"
