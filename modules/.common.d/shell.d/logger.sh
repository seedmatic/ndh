#!/usr/bin/env bash
# Shared shell logging wrapper (@codebase)
# Platform layers (darwin/nixos) may provide LOGGER_CMD="<logger> ... %TAG%".

ndh::logger:command:resolve() {
	# Expects LOGGER_CMD from caller with %TAG% placeholder; otherwise no logger.
	local tag="$1"
	if [ -z "${LOGGER_CMD:-}" ]; then
		if [ -x "/usr/bin/logger" ]; then
			LOGGER_CMD="/usr/bin/logger -t %TAG%"
		else
			local logger_bin
			logger_bin="$(command -v logger 2>/dev/null || true)"
			if [ -n "$logger_bin" ]; then
				LOGGER_CMD="$logger_bin -t %TAG%"
			fi
		fi
	fi

	if [ -n "${LOGGER_CMD:-}" ]; then
		local rendered
		rendered=${LOGGER_CMD//%TAG%/$tag}
		echo "$rendered"
		return
	fi

	echo ""
}

ndh::logger:log-file:prepare() {
	# Optional local log sink. If ACTIVATION_LOG_SESSION_ID is provided, truncate
	# the local log only when the session id changes (i.e., once per activation).
	local log_file="${ACTIVATION_LOG_FILE:-}"
	if [ -z "$log_file" ]; then
		return
	fi

	mkdir -p "$(dirname "$log_file")"

	local session_id="${ACTIVATION_LOG_SESSION_ID:-}"
	if [ -n "$session_id" ]; then
		local session_file
		session_file="${ACTIVATION_LOG_SESSION_FILE:-${log_file}.session}"

		local previous=""
		if [ -r "$session_file" ]; then
			previous="$(cat "$session_file" 2>/dev/null || true)"
		fi

		if [ "$previous" != "$session_id" ]; then
			: >"$log_file"
			printf '%s\n' "$session_id" >"$session_file"
		fi
	fi
}

ndh::logger:lines:tag() {
	# ndh::logger:lines:tag <tag> [cmd...]
	local tag="$1"
	shift

	if [ "$#" -eq 0 ]; then
		while IFS= read -r line; do
			printf '[%s] %s\n' "$tag" "$line"
		done
	else
		while IFS= read -r line; do
			printf '[%s] %s\n' "$tag" "$line"
		done | "$@"
	fi
}

ndh::logger:hints:resolve() {
	# ndh::logger:hints:resolve <tag>
	# Populates:
	# - NDH_LOG_HINT_SHOW_LABEL
	# - NDH_LOG_HINT_SHOW_CMD
	# - NDH_LOG_HINT_STREAM_LABEL
	# - NDH_LOG_HINT_STREAM_CMD
	if [ "$#" -ne 1 ]; then
		echo "[ndh::logger:hints:resolve] usage: ndh::logger:hints:resolve <tag>" >&2
		return 1
	fi

	local tag="$1"
	local os_name
	os_name="$(uname -s 2>/dev/null || echo unknown)"

	case "$os_name" in
	Darwin)
		NDH_LOG_HINT_SHOW_LABEL="macOS unified log (recent)"
		NDH_LOG_HINT_STREAM_LABEL="macOS unified log (follow)"
		NDH_LOG_HINT_SHOW_CMD="log show --style compact --last 15m --predicate 'eventMessage CONTAINS \"[$tag]\"'"
		NDH_LOG_HINT_STREAM_CMD="log stream --style compact --predicate 'eventMessage CONTAINS \"[$tag]\"'"
		;;
	*)
		NDH_LOG_HINT_SHOW_LABEL="journald (recent)"
		NDH_LOG_HINT_STREAM_LABEL="journald (follow)"
		NDH_LOG_HINT_SHOW_CMD="journalctl -t '$tag' --since '15 min ago' -o short-precise --no-pager"
		NDH_LOG_HINT_STREAM_CMD="journalctl -t '$tag' -f -o short-precise"
		;;
	esac
}

ndh::logger:streams:configure-redirect() {
	local tag="$1"

	local logger_cmd_raw
	logger_cmd_raw=$(ndh::logger:command:resolve "$tag")

	ndh::logger:log-file:prepare
	local activation_log_file="${ACTIVATION_LOG_FILE:-}"

	# Split LOGGER_CMD into an array so args with spaces become distinct words.
	local -a logger_cmd=()
	if [ -n "$logger_cmd_raw" ]; then
		# shellcheck disable=SC2206
		logger_cmd=($logger_cmd_raw)
	fi

	case "${#logger_cmd[@]}" in
	0)
		if [ -n "$activation_log_file" ]; then
			exec > >(ndh::logger:lines:tag "$tag" | tee -a "$activation_log_file" >&2) \
			2> >(ndh::logger:lines:tag "$tag" | tee -a "$activation_log_file" >&2)
		else
			exec > >(ndh::logger:lines:tag "$tag" >&2) \
			2> >(ndh::logger:lines:tag "$tag" >&2)
		fi
		;;
	*)
		if [ -n "$activation_log_file" ]; then
			exec > >(ndh::logger:lines:tag "$tag" | tee -a "$activation_log_file" | "${logger_cmd[@]}") \
			2> >(ndh::logger:lines:tag "$tag" | tee -a "$activation_log_file" | "${logger_cmd[@]}")
		else
			exec > >(ndh::logger:lines:tag "$tag" "${logger_cmd[@]}") \
			2> >(ndh::logger:lines:tag "$tag" "${logger_cmd[@]}")
		fi
		;;
	esac
}

ndh::logger:streams:redirect() {
	# ndh::logger:streams:redirect <tag>
	if [ "$#" -ne 1 ]; then
		echo "[ndh::logger:streams:redirect] usage: ndh::logger:streams:redirect <tag>" >&2
		return 1
	fi

	local tag="$1"

	# Keep original stderr handle for critical notices when needed.
	exec 3>&2
	ndh::logger:streams:configure-redirect "$tag"
}

ndh::logger:stderr:redirect() {
	# ndh::logger:stderr:redirect <tag>
	if [ "$#" -ne 1 ]; then
		echo "[ndh::logger:stderr:redirect] usage: ndh::logger:stderr:redirect <tag>" >&2
		return 1
	fi

	local tag="$1"

	# Keep original stderr handle for critical notices when needed.
	exec 3>&2

	local logger_cmd_raw
	logger_cmd_raw=$(ndh::logger:command:resolve "$tag")

	ndh::logger:log-file:prepare
	local activation_log_file="${ACTIVATION_LOG_FILE:-}"

	local -a logger_cmd=()
	if [ -n "$logger_cmd_raw" ]; then
		# shellcheck disable=SC2206
		logger_cmd=($logger_cmd_raw)
	fi

	case "${#logger_cmd[@]}" in
	0)
		if [ -n "$activation_log_file" ]; then
			exec 2> >(ndh::logger:lines:tag "$tag" | tee -a "$activation_log_file" >&2)
		else
			exec 2> >(ndh::logger:lines:tag "$tag" >&2)
		fi
		;;
	*)
		if [ -n "$activation_log_file" ]; then
			exec 2> >(ndh::logger:lines:tag "$tag" | tee -a "$activation_log_file" | "${logger_cmd[@]}")
		else
			exec 2> >(ndh::logger:lines:tag "$tag" "${logger_cmd[@]}")
		fi
		;;
	esac
}

ndh::logger:command:run() {
	if [ "$#" -lt 2 ]; then
		echo "[ndh::logger:command:run] usage: ndh::logger:command:run <tag> <command> [args...]" >&2
		exit 1
	fi

	local caller_src
	caller_src=${BASH_SOURCE[1]:-$0}

	local tag="$1"
	shift

	ndh::logger:hints:resolve "$tag"

	echo "[$tag] ndh::logger:command:starting logged command: \"${caller_src} ${*:2}\" with PID $$"
	echo "[$tag] ndh::logger:command:${NDH_LOG_HINT_SHOW_LABEL}: ${NDH_LOG_HINT_SHOW_CMD}"
	echo "[$tag] ndh::logger:command:${NDH_LOG_HINT_STREAM_LABEL}: ${NDH_LOG_HINT_STREAM_CMD}"

	# Keep a handle to original stderr so we can always emit critical notices to
	# the invoking console, even after output redirection to logger/file sinks.
	exec 3>&2
	ndh::logger:stderr:redirect "$tag"

	set -x
	local rc=0
	if "$@"; then
		echo "[$tag] ndh::logger:command:run completed successfully"
	else
		rc=$?
		echo "[$tag] ndh::logger:command:run failed"
		if [ -n "${ACTIVATION_LOG_FILE:-}" ]; then
			printf '[%s] ndh::logger:command:run error details: %s\n' "$tag" "${ACTIVATION_LOG_FILE}" >&3
		fi
	fi
	set +x
	return "$rc"
}
