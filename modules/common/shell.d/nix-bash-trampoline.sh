#!/usr/bin/env bash
# @codebase
# Shared trampoline for Bash scripts.
# Goals:
#  1) Load baseline Nix profile environment when available.
#  2) Re-exec under a Nix-managed bash when current bash is non-Nix.

[[ "${NDH_BASH_TRAMPOLINED:-0}" == "1" ]] && return 0

ndh::nix:bash:path() {
	local -a binDirs
	binDirs=( "/run/current-system/sw/bin" )

    [[ -d "/run/wrappers/bin" ]] && binDirs=( "/run/wrappers/bin" "${binDirs[@]}" )

    local path
	path="$(IFS=:; echo "${binDirs[*]}")"
	if [[ -n "${PATH:-}" ]]; then
		path="${path}:${PATH}"
	fi
	ndh::nix:bash:path:deduplicate "$path"
}

ndh::nix:bash:path:deduplicate() {
	local path kept already_present
	local -a paths=()
	local -a unique_paths=()
	local IFS=:

	read -r -a paths <<< "${1:-}"
	for path in "${paths[@]}"; do
		[[ -n "$path" ]] || continue

		already_present=0
		for kept in "${unique_paths[@]}"; do
			if [[ "$kept" == "$path" ]]; then
				already_present=1
				break
			fi
		done

		[[ "$already_present" == "1" ]] && continue
		unique_paths+=("$path")
	done
	echo "${unique_paths[*]}"
}

ndh::nix:bash:trampoline() {
	case "$(realpath -e "$BASH" 2>/dev/null || true)" in
		/nix/store/*)
			return 0
			;;
	esac
	NDH_BASH_TRAMPOLINED=1
	export NDH_BASH_TRAMPOLINED
	exec "$(command -v bash)" "$0" "${@}"
}

ndh::nix:profile:script() {
	local candidate
	local -a candidates=()

	if [[ -n "${SUDO_USER:-}" && -d "/etc/profiles/per-user/${SUDO_USER}" ]]; then
		candidates+=("/etc/profiles/per-user/${SUDO_USER}/etc/profile.d/nix-daemon.sh")
	fi

	if [[ -n "${USER:-}" && -d "/etc/profiles/per-user/${USER}" ]]; then
		candidates+=("/etc/profiles/per-user/${USER}/etc/profile.d/nix-daemon.sh")
	fi

	candidates+=(
		"/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh"
		"/run/current-system/sw/etc/profile.d/nix-daemon.sh"
	)

	for candidate in "${candidates[@]}"; do
		if [[ -r "$candidate" ]]; then
			echo "$candidate"
			return 0
		fi
	done

	return 1
}

: "Load nix profile"
if nix_daemon_profile_script="$(ndh::nix:profile:script)"; then
	# shellcheck disable=SC1091
	source "$nix_daemon_profile_script"
else
	echo "[ndh][WARN] unable to find nix-daemon profile script; continuing with PATH bootstrap only" >&2
fi

: "Cleanup path"
PATH="$(ndh::nix:bash:path)"
export PATH

: "Re-exec bash is not in the nix store"
ndh::nix:bash:trampoline "$@"
