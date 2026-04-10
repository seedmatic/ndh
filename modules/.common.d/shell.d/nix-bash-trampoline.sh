#!/usr/bin/env bash
# @codebase
# Shared trampoline for Bash scripts.
# Goals:
#  1) Load baseline Nix profile environment when available.
#  2) Re-exec under a Nix-managed bash when current bash is non-Nix.

[[ "${NDH_BASH_TRAMPOLINED:-0}" == "1" ]] && return 0

ndh::env:user:home() {
	local user="$1"
	local passwd_entry resolved_home

	[[ -n "$user" ]] || return 1

	if command -v getent >/dev/null 2>&1; then
		passwd_entry="$(getent passwd "$user" 2>/dev/null || true)"
		if [[ -n "$passwd_entry" ]]; then
			resolved_home="$(awk -F: '{print $6}' <<<"$passwd_entry")"
		fi
	fi

	if [[ -z "${resolved_home:-}" ]] && command -v dscl >/dev/null 2>&1; then
		resolved_home="$(dscl . -read "/Users/${user}" NFSHomeDirectory 2>/dev/null | awk '/NFSHomeDirectory:/ {print $2}')"
	fi

	[[ -n "${resolved_home:-}" ]] || return 1
	echo "$resolved_home"
}

ndh::bootstrap:profile:dir() {
	local profile_name
	profile_name="io-nxmatic-nix-darwin-home-bootstrap-runtime"

	if [[ -n "${NDH_BOOTSTRAP_PROFILE_OWNER:-}" ]]; then
		echo "/nix/var/nix/profiles/per-user/${NDH_BOOTSTRAP_PROFILE_OWNER}/${profile_name}"
		return 0
	fi

	# Canonical default when no explicit owner is provided.
	if [[ -d "/nix/var/nix/profiles/per-user/root" ]]; then
		echo "/nix/var/nix/profiles/per-user/root/${profile_name}"
		return 0
	fi

	if [[ -n "${NDH_BOOTSTRAP_PROFILE_DIR:-}" ]]; then
		echo "${NDH_BOOTSTRAP_PROFILE_DIR}"
		return 0
	fi

	if [[ -n "${NDH_BOOTSTRAP_PROFILE_BIN:-}" ]]; then
		echo "${NDH_BOOTSTRAP_PROFILE_BIN%/bin}"
		return 0
	fi

	if [[ -n "${SUDO_USER:-}" ]]; then
		echo "/nix/var/nix/profiles/per-user/${SUDO_USER}/${profile_name}"
		return 0
	fi

	if [[ -n "${USER:-}" ]]; then
		echo "/nix/var/nix/profiles/per-user/${USER}/${profile_name}"
		return 0
	fi

	if [[ -n "${HOME:-}" ]]; then
		echo "${HOME}/.local/state/nix/profiles/${profile_name}"
		return 0
	fi

	return 1
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
	local profile_parent
	local discovered_installer

	nix_bin="$(command -v nix 2>/dev/null || true)"
	profile_dir="$(ndh::bootstrap:profile:dir || true)"

	if [[ -z "$nix_bin" || -z "$profile_dir" ]]; then
		return 1
	fi

	profile_name="io-nxmatic-nix-darwin-home-bootstrap-runtime"
	runtime_name="io.nxmatic.nix-darwin-home-bootstrap-runtime-activation"
	runtime_spec="${NDH_BOOTSTRAP_RUNTIME_PACKAGE:-}"
	installer="${NDH_BOOTSTRAP_INSTALLER:-}"
	[[ -n "$runtime_spec" ]] || runtime_spec=".#io-nxmatic-nix-darwin-home-prerequisites-install"
	discovered_installer="$(command -v io-nxmatic-nix-darwin-home-prerequisites-install 2>/dev/null || true)"
	if [[ -z "$installer" && -n "$discovered_installer" ]]; then
		installer="$discovered_installer"
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
	if [[ -n "$installer" && -x "$installer" ]]; then
		"$installer" "$profile_dir" >/dev/null 2>&1 || return 1
		return 0
	fi

	if [[ "$runtime_spec" == .#* ]]; then
		# Flake-relative runtime spec can fail outside a checkout; never mutate an
		# existing profile on this fallback path.
		"$nix_bin" run "$runtime_spec" -- "$profile_dir" >/dev/null 2>&1 || return 1
		return 0
	fi

	if "$nix_bin" profile add --profile "$profile_dir" "$runtime_spec" >/dev/null 2>&1; then
		return 0
	fi

	# Retry once after clearing known legacy/runtime entries to handle file conflicts.
	"$nix_bin" profile remove --profile "$profile_dir" "$runtime_name" >/dev/null 2>&1 || true
	"$nix_bin" profile remove --profile "$profile_dir" "$profile_name" >/dev/null 2>&1 || true

	"$nix_bin" profile add --profile "$profile_dir" "$runtime_spec" >/dev/null 2>&1 || return 1

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
	local profile_dir install_hint installer_hint
	profile_dir="$(ndh::bootstrap:profile:dir || true)"
	installer_hint="${NDH_BOOTSTRAP_INSTALLER:-$(command -v io-nxmatic-nix-darwin-home-prerequisites-install 2>/dev/null || true)}"
	if [[ -n "$profile_dir" ]]; then
		if [[ -n "$installer_hint" ]]; then
			install_hint="${installer_hint} ${profile_dir}"
		else
			install_hint="nix run .#io-nxmatic-nix-darwin-home-prerequisites-install -- ${profile_dir}"
		fi
	else
		if [[ -n "$installer_hint" ]]; then
			install_hint="${installer_hint} /nix/var/nix/profiles/per-user/root/io-nxmatic-nix-darwin-home-bootstrap-runtime"
		else
			install_hint="nix run .#io-nxmatic-nix-darwin-home-prerequisites-install -- /nix/var/nix/profiles/per-user/root/io-nxmatic-nix-darwin-home-bootstrap-runtime"
		fi
	fi

	# Keep this function self-contained: ensure caller-independent PATH priming
	# before any install/verify attempt.
	PATH="$(ndh::nix:bash:path)"
	PATH="$(ndh::bootstrap:runtime:path)"
	hash -r 2>/dev/null || true

	ndh::bootstrap:runtime:install || true

	# Refresh runtime PATH after a potential install so newly provisioned
	# profile binaries are immediately discoverable in this shell process.
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
