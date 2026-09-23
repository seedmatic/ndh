#!/usr/bin/env -S bash -euo pipefail
# baremetal-link-deploy — install/refresh the baremetal-link LaunchDaemon on the
# corporate bare-metal Mac.  The daemon uses only macOS system tools (ifconfig,
# route, launchctl) and is bash-3.2 compatible, so NO nix runtime is needed on
# the target: we deliver the rendered install script as TEXT over ssh and run it
# with sudo.  That keeps the deploy runnable from anywhere `ssh <vz-host>`
# resolves — the operator's Mac or nikopol-nixos's activation oneshot (which is
# aarch64-linux and could not hold a darwin closure anyway).
#
# Base: the shared bash trampoline (nix-managed bash + logger + stable env), like
# the other operator apps.  The whole run (reachability probe + ssh pipe) is
# traced into the unified log under ndh::logger:command:run; milestones surface
# on the terminal via ndh::logger:notice.  ssh is pinned by store path (@ssh@)
# because the trampoline owns PATH.
#
# Build-time tokens (pkgs.replaceVars): nixBashTrampoline, loggerTag, ssh, timeout,
# installScript / uninstallScript (rendered script store paths), vzHost (default
# ssh target), bootstrapHost (the out-of-band LAN name), and systemKeysDir (where the
# enrich pipeline lands the vz-nudge private+cert, read at runtime and shipped to
# the target) — written WITHOUT at-sigils (replaceVars would substitute them in
# this comment too).
#
# Usage: <host>-baremetal-link-deploy [vz-host] [--uninstall]
source @nixBashTrampoline@

main() {
	local vz_host="@vzHost@"
	if (($# > 0)) && [[ "$1" != --* ]]; then
		vz_host="$1"
		shift
	fi

	# --uninstall selects the teardown script; default is install.  Both are
	# rendered from the same catalog values, so an uninstall undoes exactly what
	# the matching install put in place.
	local script="@installScript@" action="install"
	case "${1:-}" in
	--uninstall)
		script="@uninstallScript@"
		action="uninstall"
		shift
		;;
	--install) shift ;;
	esac

	# vzhost REFUSES root ssh, and the activation oneshot runs as root — so connect
	# as the operator login (@vzUser@) with the CA-signed rdp-host identity from the
	# root-readable systemKeysDir (vzhost trusts the mammoth-skate CA inbound for that
	# user). If that identity isn't readable (a non-root `nix run`), omit -i and let
	# the caller's ssh config/agent supply auth — still forcing user @vzUser@.
	# accept-new writes known_hosts on first contact.
	local vzId="@systemKeysDir@/rdp-host"
	local -a sshVz=(@ssh@ -l "@vzUser@" -o StrictHostKeyChecking=accept-new)
	if [[ -r "$vzId" && -r "$vzId-cert.pub" ]]; then
		sshVz+=(-i "$vzId" -o "CertificateFile=$vzId-cert.pub" -o IdentitiesOnly=yes)
	fi

	# Two ways in, tried in order. `vzhost.<host>` is the segment name this daemon is
	# what CREATES, so on a first run — or right after the segment is renumbered — it
	# does not resolve, and @bootstrapHost@ is the out-of-band path: the vz-host's
	# LAN name, served by the LAN's own DNS and therefore independent of the segment.
	#
	# It used to be `<domain>.local`, which was WRONG the moment the bare-metal is not
	# itself named after the segment: on nikopol that mDNS name is the vz GUEST VM, a
	# different machine, and the deploy cheerfully addressed it. It is now the LAN name
	# declared in the catalog beside the vz-host's own DHCP reservation — which also
	# happens to be the name the operator's ssh config has a Host block for, so the
	# identity resolves too.
	#
	# The probe is HARD-bounded. `ConnectTimeout` does not cover NAME RESOLUTION, and
	# when the segment resolver is the thing that just moved, resolving `vzhost.<host>`
	# hangs on it: measured at 30s against a 5s ConnectTimeout, which is also what made
	# the activation oneshot burn 15s before failing.
	local -a probe=(@timeout@ 8 "${sshVz[@]}" -o BatchMode=yes -o ConnectTimeout=5)
	local target=""
	local candidate
	for candidate in "$vz_host" "@bootstrapHost@"; do
		if "${probe[@]}" "$candidate" true 2>/dev/null; then
			target="$candidate"
			break
		fi
		ndh::logger:notice "[baremetal-link-deploy] ${candidate} unreachable"
	done
	if [[ -z "$target" ]]; then
		ndh::logger:notice "[baremetal-link-deploy] FAILED: neither ${vz_host} nor @bootstrapHost@ answered — NOTHING was applied"
		return 1
	fi

	ndh::logger:notice "[baremetal-link-deploy] ${action} on ${target} (sudo, from stdin)"
	# Pipe the chosen rendered script to the target and run it as root.  Idempotent
	# on the target (install: bootout -> bootstrap); sudo is NOPASSWD on the vz host.
	#
	# The status is checked EXPLICITLY, not left to errexit: this function is invoked
	# through `ndh::logger:command:run`, which calls it after `local rc=0` and so
	# neutralises `set -e` inside it. Without this check a refused ssh was followed by
	# `ndh::logger:command:run completed successfully` — the tool reporting success for
	# an install that never happened, which is how a daemon came to be believed
	# deployed on a machine it had never reached.
	if ! "${sshVz[@]}" "$target" sudo /bin/bash -s <"$script"; then
		ndh::logger:notice "[baremetal-link-deploy] FAILED: ${action} on ${target} did not complete — NOTHING was applied"
		return 1
	fi

	# Ship the vz-nudge daemon identity (private + user cert) so the installed
	# link-up.sh can authenticate to the guest for its reconfigure-nudge. Read from
	# THIS host's enriched systemKeysDir at RUNTIME — the enrich pipeline regenerates
	# + re-signs the keypair each activation, and rotation is transparent to the guest
	# (it trusts the mammoth-skate CA via TrustedUserCAKeys, not a pinned key). Never
	# goes through the nix store; delivered over the same ssh, written root-only.
	# Skipped on --uninstall or when the material is absent on this host, in which
	# case the nudge stays inert and the manual `networkctl reconfigure lan-br`
	# fallback still applies.
	local vzNudgeKey="@systemKeysDir@/vz-nudge" vzNudgeCert="@systemKeysDir@/vz-nudge-cert.pub"
	if [[ "$action" == "install" && -r "$vzNudgeKey" && -r "$vzNudgeCert" ]]; then
		ndh::logger:notice "[baremetal-link-deploy] shipping vz-nudge identity to ${target}"
		# One ssh + one `sudo bash` on the target (like the install pipe above): a
		# script transported as ssh stdin, run as root. `install -d` sets the dir mode
		# in one shot. `umask 077` guards the WRITE window (a re-created private is
		# never transiently 0644); the explicit `chmod`s make the final modes
		# DETERMINISTIC even when the files already exist (umask/`cat >` don't change an
		# existing file's mode; BSD `install` can't read pipes, so no `install -m` from
		# a heredoc without a temp). Outer heredoc UNQUOTED → local `$(cat …)` embeds
		# the private + cert; INNER delimiters quoted → written verbatim; set -eu aborts
		# on a failed write.
		"${sshVz[@]}" "$target" sudo /bin/bash -s <<REMOTE
set -eu
install -d -m 700 /var/root/.ssh
umask 077
cat > /var/root/.ssh/vz-nudge <<'VZ_NUDGE_PRIV'
$(cat "$vzNudgeKey")
VZ_NUDGE_PRIV
cat > /var/root/.ssh/vz-nudge-cert.pub <<'VZ_NUDGE_CERT'
$(cat "$vzNudgeCert")
VZ_NUDGE_CERT
chmod 600 /var/root/.ssh/vz-nudge
chmod 644 /var/root/.ssh/vz-nudge-cert.pub
REMOTE
	elif [[ "$action" == "install" ]]; then
		ndh::logger:notice "[baremetal-link-deploy] vz-nudge identity absent here (${vzNudgeKey}) — nudge stays inert (manual reconfigure fallback)"
	fi
}

ndh::logger:command:run "@loggerTag@" main "$@"
