#!/usr/bin/env bash
# @codebase
# Shared trampoline for Bash scripts.
# Goals:
#  1) Load baseline Nix profile environment when available.
#  2) Re-exec under a Nix-managed bash when current bash is non-Nix.

[[ "${NDH_BASH_TRAMPOLINED:-0}" == "1" ]] && return 0

ndh::bootstrap:profile:bin() {
	local candidate
	local -a candidates=()

	[[ -n "${NDH_BOOTSTRAP_PROFILE_BIN:-}" ]] && candidates+=("${NDH_BOOTSTRAP_PROFILE_BIN}")
	[[ -n "${HOME:-}" ]] && candidates+=("${HOME}/.local/state/nix/profiles/ndh-bootstrap-runtime/bin")

	if [[ -n "${SUDO_USER:-}" ]]; then
		candidates+=("/nix/var/nix/profiles/per-user/${SUDO_USER}/ndh-bootstrap-runtime/bin")
	fi

	if [[ -n "${USER:-}" ]]; then
		candidates+=("/nix/var/nix/profiles/per-user/${USER}/ndh-bootstrap-runtime/bin")
	fi

	candidates+=("/nix/var/nix/profiles/per-user/root/ndh-bootstrap-runtime/bin")

	for candidate in "${candidates[@]}"; do
		[[ -n "$candidate" ]] || continue
		if [[ -d "$candidate" ]]; then
			echo "$candidate"
			return 0
		fi
	done

	return 1
}

ndh::bootstrap:runtime:path() {
	local profile_bin
	profile_bin="$(ndh::bootstrap:profile:bin || true)"
	if [[ -n "$profile_bin" ]]; then
		echo "${profile_bin}:${PATH:-}"
	else
		echo "${PATH:-}"
	fi
}

ndh::bootstrap:runtime:verify() {
	local required raw_cmd cmd
	local -a missing=()
	read -r -a required <<< "${NDH_BOOTSTRAP_REQUIRED_COMMANDS:-age age-keygen awk sed grep ssh ssh-keygen yq git}"

	for raw_cmd in "${required[@]}"; do
		cmd="${raw_cmd}"
		[[ -n "$cmd" ]] || continue
		if ! command -v "$cmd" >/dev/null 2>&1; then
			missing+=("$cmd")
		fi
	done

	if ((${#missing[@]} > 0)); then
		echo "[ndh][WARN] bootstrap runtime profile missing commands: ${missing[*]}" >&2
		return 1
	fi

	return 0
}

ndh::bootstrap:runtime:ensure() {
	if ndh::bootstrap:runtime:verify; then
		return 0
	fi

	if [[ "${NDH_BOOTSTRAP_STRICT:-1}" == "1" ]]; then
		echo "[ndh][ERROR] required NDH bootstrap profile is missing/incomplete" >&2
		echo "[ndh][ERROR] install hint: ${NDH_BOOTSTRAP_INSTALL_HINT:-nix run .#ndh-bootstrap-profile-installer -- \$HOME/.local/state/nix/profiles/ndh-bootstrap-runtime}" >&2
		return 1
	fi

	return 0
}

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

ndh::env:ensure:home() {
	[[ -n "${HOME:-}" ]] && return 0

	local effective_user effective_uid passwd_entry resolved_home
	effective_user="${SUDO_USER:-${USER:-$(id -un 2>/dev/null || true)}}"
	effective_uid="$(id -u 2>/dev/null || echo 0)"
	resolved_home=""

	if command -v getent >/dev/null 2>&1 && [[ -n "$effective_user" ]]; then
		passwd_entry="$(getent passwd "$effective_user" 2>/dev/null || true)"
		if [[ -n "$passwd_entry" ]]; then
			resolved_home="$(awk -F: '{print $6}' <<<"$passwd_entry")"
		fi
	fi

	if [[ -z "$resolved_home" ]]; then
		if [[ "$effective_uid" -eq 0 ]]; then
			resolved_home="/root"
		else
			resolved_home="/var/empty"
		fi
	fi

	HOME="$resolved_home"
	export HOME
}

: "Load nix profile"
ndh::env:ensure:home
if nix_daemon_profile_script="$(ndh::nix:profile:script)"; then
	# shellcheck disable=SC1091
	source "$nix_daemon_profile_script"
else
	echo "[ndh][WARN] unable to find nix-daemon profile script; continuing with PATH bootstrap only" >&2
fi

: "Cleanup path"
PATH="$(ndh::nix:bash:path)"
PATH="$(ndh::bootstrap:runtime:path)"
export PATH

: "Verify bootstrap runtime profile"
ndh::bootstrap:runtime:ensure

: "Re-exec bash is not in the nix store"
ndh::nix:bash:trampoline "$@"
