#!/usr/bin/env bash
# @codebase
# Shared trampoline for Bash scripts.
# Goals:
#  1) Load baseline Nix profile environment when available.
#  2) Re-exec under a Nix-managed bash when current bash is non-Nix.

ndh::logger:bootstrap:load() {
	local trampoline_dir=""
	local logger_script=""
	local source_path=""

	source_path="${BASH_SOURCE[0]}"
	if [[ "$source_path" == */* ]]; then
		trampoline_dir="$(cd "${source_path%/*}" && pwd -P)"
	else
		trampoline_dir="$(pwd -P)"
	fi
	logger_script="${trampoline_dir}/logger.sh"

	if [[ ! -r "$logger_script" ]]; then
		echo "[ndh][ERROR] required nix bash logger missing/unreadable: $logger_script" >&2
		return 1
	fi

	# shellcheck disable=SC1090
	source "$logger_script"
}

if ! ndh::logger:bootstrap:load; then
	return 1 2>/dev/null || exit 1
fi

[[ "${NDH_BASH_TRAMPOLINED:-0}" == "1" ]] && return 0

ndh::env:user:home() {
	local user="$1"
	local passwd_entry resolved_home

	[[ -n "$user" ]] || return 1

	if command -v getent >/dev/null 2>&1; then
		passwd_entry="$(getent passwd "$user" 2>/dev/null || true)"
		if [[ -n "$passwd_entry" ]]; then
			IFS=: read -r _ _ _ _ _ resolved_home _ <<<"$passwd_entry"
		fi
	fi

	if [[ -z "${resolved_home:-}" ]] && command -v dscl >/dev/null 2>&1; then
		resolved_home="$(dscl . -read "/Users/${user}" NFSHomeDirectory 2>/dev/null | awk '/NFSHomeDirectory:/ {print $2}')"
	fi

	[[ -n "${resolved_home:-}" ]] || return 1
	echo "$resolved_home"
}

ndh::bootstrap:profile:dir() {
	# Canonical policy: root-owned dedicated NDH bringup profile.
	if [[ -n "${NDH_BOOTSTRAP_PROFILE_DIR:-}" ]]; then
		echo "${NDH_BOOTSTRAP_PROFILE_DIR}"
		return 0
	fi
	echo "/nix/var/nix/profiles/per-user/root/io-nxmatic-nix-darwin-home-bringup-runtime"
	return 0
}

ndh::bootstrap:profile:bin() {
	local profile_dir
	profile_dir="$(ndh::bootstrap:profile:dir || true)"
	[[ -n "$profile_dir" ]] || return 1
	echo "${profile_dir}/bin"
	return 0
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
	local required raw_cmd cmd profile_bin
	local -a missing=()
	local -a missing_profile_bin=()
	profile_bin="$(ndh::bootstrap:profile:bin || true)"

	if [[ -z "$profile_bin" || ! -d "$profile_bin" ]]; then
		echo "[ndh][WARN] bootstrap runtime profile bin directory missing: ${profile_bin:-<unset>}" >&2
		return 1
	fi

	read -r -a required <<< "${NDH_BOOTSTRAP_REQUIRED_COMMANDS:-bash nix age age-keygen awk sed grep ssh ssh-keygen yq git}"

	for raw_cmd in "${required[@]}"; do
		cmd="${raw_cmd}"
		[[ -n "$cmd" ]] || continue
		if [[ ! -e "$profile_bin/$cmd" && ! -L "$profile_bin/$cmd" ]]; then
			missing_profile_bin+=("$cmd")
		fi
		if ! command -v "$cmd" >/dev/null 2>&1; then
			missing+=("$cmd")
		fi
	done

	if ((${#missing_profile_bin[@]} > 0)); then
		echo "[ndh][WARN] bootstrap runtime profile bin missing commands: ${missing_profile_bin[*]}" >&2
		return 1
	fi

	if ((${#missing[@]} > 0)); then
		echo "[ndh][WARN] bootstrap runtime profile missing commands: ${missing[*]}" >&2
		return 1
	fi

	return 0
}

ndh::bootstrap:runtime:install() {
	local nix_bin profile_dir profile_name runtime_name runtime_spec installer
	local nix_cli_args_raw
	local -a nix_cli_args=()
	local profile_parent
	local discovered_installer
	local install_attr host_short

	profile_dir="$(ndh::bootstrap:profile:dir || true)"
	runtime_name="$(basename "${profile_dir:-/nix/var/nix/profiles/per-user/root/io-nxmatic-nix-darwin-home-bringup-runtime}")"
	runtime_attr_name="$runtime_name"
	install_attr="${NDH_BOOTSTRAP_INSTALL_ATTR:-}"
	if [[ -z "$install_attr" ]]; then
		host_short="$(hostname -s 2>/dev/null || true)"
		if [[ -n "$host_short" ]]; then
			install_attr="${host_short}-nixos-bringup-install"
		fi
	fi
	runtime_spec="${NDH_BOOTSTRAP_RUNTIME_PACKAGE:-}"
	installer="${NDH_BOOTSTRAP_INSTALLER:-}"
	if [[ -z "$runtime_spec" ]]; then
		if [[ -n "$install_attr" ]]; then
			runtime_spec=".#${install_attr}"
		else
			runtime_spec=".#$(hostname -s 2>/dev/null || echo host)-nixos-bringup-install"
		fi
	fi
	discovered_installer="$(command -v nerd-bringup-install 2>/dev/null || true)"
	if [[ -z "$installer" && -n "$discovered_installer" ]]; then
		installer="$discovered_installer"
	fi

	nix_bin="$(command -v nix 2>/dev/null || true)"
	nix_cli_args_raw="${NDH_NIX_CLI_ARGS:--L -v -v}"
	if [[ -n "$nix_cli_args_raw" ]]; then
		read -r -a nix_cli_args <<< "$nix_cli_args_raw"
	fi
	if [[ -z "$profile_dir" ]]; then
		return 1
	fi

	profile_parent="$(dirname "$profile_dir")"
	# In non-root contexts (e.g., KnownHostsCommand), avoid noisy permission
	# failures by skipping auto-install when profile parent is not writable.
	if [[ ! -d "$profile_parent" ]]; then
		if [[ ! -w "$(dirname "$profile_parent")" ]]; then
			return 1
		fi
	else
		if [[ ! -w "$profile_parent" ]]; then
			return 1
		fi
	fi

	install -d -m 0755 "$profile_parent"

	# Bootstrap fallback for early image-build contexts: if nix is not yet
	# available but the runtime package path is already in the environment,
	# seed the canonical profile path directly from the store.
	if [[ -z "$nix_bin" && "$runtime_spec" == /nix/store/* && -d "$runtime_spec/bin" ]]; then
		if [[ ! -e "$profile_dir" || -L "$profile_dir" ]]; then
			ln -sfn "$runtime_spec" "$profile_dir"
			return 0
		fi

		if [[ -d "$profile_dir" && ! -e "$profile_dir/bin" ]]; then
			ln -sfn "$runtime_spec/bin" "$profile_dir/bin"
			return 0
		fi
	fi

	if [[ -z "$nix_bin" ]]; then
		return 1
	fi

	if [[ -n "$installer" && -x "$installer" ]]; then
		"$installer" "$profile_dir" >/dev/null 2>&1 || return 1
		return 0
	fi

	if [[ "$runtime_spec" == .#* ]]; then
		# Flake-relative runtime spec can fail outside a checkout; never mutate an
		# existing profile on this fallback path.
		"$nix_bin" "${nix_cli_args[@]}" run "$runtime_spec" -- "$profile_dir" >/dev/null 2>&1 || return 1
		return 0
	fi

	if "$nix_bin" "${nix_cli_args[@]}" profile add --profile "$profile_dir" "$runtime_spec" >/dev/null 2>&1; then
		return 0
	fi

	# Retry once after clearing known legacy/runtime entries to handle file conflicts.
	"$nix_bin" "${nix_cli_args[@]}" profile remove --profile "$profile_dir" "$runtime_name" >/dev/null 2>&1 || true
	"$nix_bin" "${nix_cli_args[@]}" profile remove --profile "$profile_dir" "$runtime_attr_name" >/dev/null 2>&1 || true

	"$nix_bin" "${nix_cli_args[@]}" profile add --profile "$profile_dir" "$runtime_spec" >/dev/null 2>&1 || return 1

	return 0
}

ndh::bootstrap:runtime:diagnose() {
	local profile_dir profile_bin required raw_cmd
	local -a required_cmds=()

	diag_command() {
		local cmd="$1"
		local resolved
		resolved="$(command -v "$cmd" 2>/dev/null || true)"
		echo "[ndh][DIAG] command -v ${cmd}: ${resolved:-<missing>}" >&2
		if [[ -n "$profile_bin" ]]; then
			if [[ -e "$profile_bin/$cmd" || -L "$profile_bin/$cmd" ]]; then
				ls -l "$profile_bin/$cmd" >&2 || true
			else
				echo "[ndh][DIAG] missing file: $profile_bin/$cmd" >&2
			fi
		fi
	}

	profile_dir="$(ndh::bootstrap:profile:dir || true)"
	profile_bin="$(ndh::bootstrap:profile:bin || true)"
	required="${NDH_BOOTSTRAP_REQUIRED_COMMANDS:-bash nix age age-keygen awk sed grep ssh ssh-keygen yq git}"
	read -r -a required_cmds <<< "$required"

	echo "[ndh][DIAG] bootstrap profile dir: ${profile_dir:-<unset>}" >&2
	echo "[ndh][DIAG] bootstrap profile bin: ${profile_bin:-<unset>}" >&2
	echo "[ndh][DIAG] NDH_BOOTSTRAP_PROFILE_OWNER: ${NDH_BOOTSTRAP_PROFILE_OWNER:-<unset>}" >&2
	echo "[ndh][DIAG] SUDO_USER: ${SUDO_USER:-<unset>}" >&2
	echo "[ndh][DIAG] HOME: ${HOME:-<unset>}" >&2
	if [[ -n "$profile_bin" ]]; then
		if [[ -d "$profile_bin" ]]; then
			ls -ld "$profile_bin" >&2 || true
		else
			echo "[ndh][DIAG] missing directory: $profile_bin" >&2
		fi
	fi

	for raw_cmd in "${required_cmds[@]}"; do
		[[ -n "$raw_cmd" ]] || continue
		diag_command "$raw_cmd"
	done
}

ndh::bootstrap:runtime:ensure() {
	local profile_dir install_hint installer_hint install_attr host_short
	profile_dir="$(ndh::bootstrap:profile:dir || true)"
	install_attr="${NDH_BOOTSTRAP_INSTALL_ATTR:-}"
	if [[ -z "$install_attr" ]]; then
		host_short="$(hostname -s 2>/dev/null || true)"
		if [[ -n "$host_short" ]]; then
			install_attr="${host_short}-nixos-bringup-install"
		fi
	fi
	installer_hint="${NDH_BOOTSTRAP_INSTALLER:-$(command -v nerd-bringup-install 2>/dev/null || true)}"
	if [[ -n "$profile_dir" ]]; then
		if [[ -n "$installer_hint" ]]; then
			install_hint="${installer_hint} ${profile_dir}"
		else
			if [[ -n "$install_attr" ]]; then
				install_hint="nix run .#${install_attr} -- ${profile_dir}"
			else
				install_hint="nix run .#$(hostname -s 2>/dev/null || echo host)-nixos-bringup-install -- ${profile_dir}"
			fi
		fi
	else
		local profile_fallback="/nix/var/nix/profiles/per-user/root/io-nxmatic-nix-darwin-home-bringup-runtime"
		if [[ -n "$installer_hint" ]]; then
			install_hint="${installer_hint} ${profile_fallback}"
		else
			if [[ -n "$install_attr" ]]; then
				install_hint="nix run .#${install_attr} -- ${profile_fallback}"
			else
				install_hint="nix run .#$(hostname -s 2>/dev/null || echo host)-nixos-bringup-install -- ${profile_fallback}"
			fi
		fi
	fi

	# Keep this function self-contained: ensure caller-independent PATH priming
	# before any install/verify attempt.
	PATH="$(ndh::nix:bash:path)"
	PATH="$(ndh::bootstrap:runtime:path)"
	hash -r 2>/dev/null || true

	if ndh::bootstrap:runtime:verify; then
		return 0
	fi

	ndh::bootstrap:runtime:diagnose

	if [[ "${NDH_BOOTSTRAP_STRICT:-1}" == "1" ]]; then
		echo "[ndh][ERROR] required NDH bootstrap profile is missing/incomplete" >&2
		echo "[ndh][ERROR] install hint: ${NDH_BOOTSTRAP_INSTALL_HINT:-$install_hint}" >&2
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
	for path in "${paths[@]-}"; do
		[[ -n "$path" ]] || continue

		already_present=0
		for kept in "${unique_paths[@]-}"; do
			if [[ "$kept" == "$path" ]]; then
				already_present=1
				break
			fi
		done

		[[ "$already_present" == "1" ]] && continue
		unique_paths+=("$path")
	done
	if ((${#unique_paths[@]} == 0)); then
		echo ""
		return 0
	fi
	echo "${unique_paths[*]-}"
}

ndh::nix:bash:trampoline() {
	case "$(realpath -e "$BASH" 2>/dev/null || true)" in
		/nix/store/*)
			return 0
			;;
	esac
	NDH_BASH_TRAMPOLINED=1
	export NDH_BASH_TRAMPOLINED
	exec "$(command -v bash)" "$0" "$@"
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
			# Parse field 6 (home dir) with pure bash — avoids awk dependency
			# in restricted PATH environments (e.g. systemd activation).
			IFS=: read -r _ _ _ _ _ resolved_home _ <<<"$passwd_entry"
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
if [[ "${NDH_BOOTSTRAP_INSTALLER_MODE:-0}" != "1" ]]; then
	ndh::bootstrap:runtime:ensure
fi

: "Re-exec bash is not in the nix store"
ndh::nix:bash:trampoline "$@"
