#!/usr/bin/env bash
# Shared shell logging wrapper (@codebase)
# Platform layers (darwin/nixos) may provide LOGGER_CMD="<logger> ... %TAG%".

ndh::logger:run:marker:ensure() {
	# ndh::logger:run:marker:ensure [tag]
	if [ -n "${NDH_LOG_RUN_MARKER:-}" ]; then
		return 0
	fi

	local tag="${1:-unknown}"
	local base_marker=""
	local run_nonce=""
	run_nonce="$(date +%Y%m%dT%H%M%S)-$$-$RANDOM"
	if [ -n "${ACTIVATION_LOG_SESSION_ID:-}" ]; then
		base_marker="session:${ACTIVATION_LOG_SESSION_ID}:tag:${tag}:run:${run_nonce}"
		NDH_LOG_RUN_MARKER_SCOPE="activation-session-run"
	else
		base_marker="process:tag:${tag}:run:${run_nonce}"
		NDH_LOG_RUN_MARKER_SCOPE="process-run"
	fi

	NDH_LOG_RUN_MARKER="ndh-run-marker:${base_marker}"
	export NDH_LOG_RUN_MARKER
	export NDH_LOG_RUN_MARKER_SCOPE
}

ndh::logger:run:marker:emit() {
	# ndh::logger:run:marker:emit <tag>
	if [ "$#" -ne 1 ]; then
		echo "[ndh::logger:run:marker:emit] usage: ndh::logger:run:marker:emit <tag>" >&2
		return 1
	fi

	local tag="$1"
	ndh::logger:run:marker:ensure "$tag"

	if [ "${NDH_LOG_RUN_MARKER_EMITTED:-0}" != "1" ]; then
		NDH_LOG_RUN_MARKER_EMITTED=1
		export NDH_LOG_RUN_MARKER_EMITTED
		echo "[$tag] ndh::logger:run:marker ${NDH_LOG_RUN_MARKER}" >&2
	fi
}

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
	local marker="${NDH_LOG_RUN_MARKER:-}"
	local marker_scope="${NDH_LOG_RUN_MARKER_SCOPE:-unknown}"
	os_name="$(uname -s 2>/dev/null || echo unknown)"

	case "$os_name" in
	Darwin)
		if [ -n "$marker" ]; then
			case "$marker_scope" in
			activation-session)
				NDH_LOG_HINT_SHOW_LABEL="macOS unified log (from activation-session marker)"
				;;
			process-run)
				NDH_LOG_HINT_SHOW_LABEL="macOS unified log (from process-run marker)"
				;;
			*)
				NDH_LOG_HINT_SHOW_LABEL="macOS unified log (from run marker)"
				;;
			esac
			NDH_LOG_HINT_SHOW_CMD="/usr/bin/log show --style compact --last 15m --predicate 'eventMessage CONTAINS \"[$tag]\"' | awk '/${marker}/{seen=1} seen'"
		else
			NDH_LOG_HINT_SHOW_LABEL="macOS unified log (recent)"
			NDH_LOG_HINT_SHOW_CMD="/usr/bin/log show --style compact --last 15m --predicate 'eventMessage CONTAINS \"[$tag]\"'"
		fi
		NDH_LOG_HINT_STREAM_LABEL="macOS unified log (follow)"
		NDH_LOG_HINT_STREAM_CMD="/usr/bin/log stream --style compact --predicate 'eventMessage CONTAINS \"[$tag]\"'"
		;;
	Linux)
		if [ -n "$marker" ]; then
			case "$marker_scope" in
			activation-session)
				NDH_LOG_HINT_SHOW_LABEL="journald (from activation-session marker)"
				;;
			process-run)
				NDH_LOG_HINT_SHOW_LABEL="journald (from process-run marker)"
				;;
			*)
				NDH_LOG_HINT_SHOW_LABEL="journald (from run marker)"
				;;
			esac
			NDH_LOG_HINT_SHOW_CMD="journalctl -t '$tag' -o short-precise --no-pager | awk '/${marker}/{seen=1} seen'"
		else
			NDH_LOG_HINT_SHOW_LABEL="journald (recent)"
			NDH_LOG_HINT_SHOW_CMD="journalctl -t '$tag' --since '15 min ago' -o short-precise --no-pager"
		fi
		NDH_LOG_HINT_STREAM_LABEL="journald (follow)"
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
	ndh::logger:run:marker:emit "$tag"
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

	ndh::logger:run:marker:emit "$tag"
}

# The secret window: a script's critical section, untraced, the rest of it traced. The operator's rule (2026-10-21):
# the system log tells the story, xtrace included, except around the lines that handle a secret value.
#
#   ndh::secret:begin "<why>"   # writes `: "<why>"` into the trace, then turns xtrace off
#   …lines that read or use the secret…
#   ndh::secret:end             # turns xtrace back to what it was before begin
#
# The state is the shell's ($- has x), never a variable's absence. Inside a window NDH_LOGGER_XTRACE=0 is exported,
# so a child the window starts stays untraced whatever the logger's default, and BASH_ENV is unset: a caller's
# BASH_ENV holding `set -x` would trace a child bash (measured). Windows nest: each end restores what its begin
# found. A failure that stops the script inside a window leaves xtrace OFF to the end, so no error path, EXIT trap
# included, traces the value. No trap of its own: it would replace the script's.
NDH_SECRET_WAS_TRACED=() NDH_SECRET_MARKER=() NDH_SECRET_BASH_ENV=()
ndh::secret:begin() {
	local why="${1:?usage: ndh::secret:begin <why>}"
	local was=off
	case $- in *x*) was=on ;; esac
	: "secret window: ${why}"
	{ set +x; } 2>/dev/null
	NDH_SECRET_WAS_TRACED+=("$was")
	NDH_SECRET_MARKER+=("${NDH_LOGGER_XTRACE+=}${NDH_LOGGER_XTRACE-}")
	NDH_SECRET_BASH_ENV+=("${BASH_ENV+=}${BASH_ENV-}")
	export NDH_LOGGER_XTRACE=0
	unset BASH_ENV
}
# A saved value is "" when the variable was unset, "=<value>" when it was set (even to "").
ndh::secret:restore() { # <name> <saved>
	if [ -z "$2" ]; then unset "$1"; else export "$1=${2#=}"; fi
}
ndh::secret:end() {
	local n=${#NDH_SECRET_WAS_TRACED[@]}
	if ((n == 0)); then
		echo "[ndh::secret:end] no open window" >&2
		return 1
	fi
	local was="${NDH_SECRET_WAS_TRACED[n - 1]}"
	ndh::secret:restore NDH_LOGGER_XTRACE "${NDH_SECRET_MARKER[n - 1]}"
	ndh::secret:restore BASH_ENV "${NDH_SECRET_BASH_ENV[n - 1]}"
	unset 'NDH_SECRET_WAS_TRACED[n - 1]' 'NDH_SECRET_MARKER[n - 1]' 'NDH_SECRET_BASH_ENV[n - 1]'
	if [ "$was" = on ]; then set -x; fi
	: "secret window closed"
}

ndh::logger:notice() {
	# Emit a message to the INVOKING console.  ndh::logger:command:run redirects
	# fd2 to the log sink (journald / unified log) but first preserves the
	# original stderr as fd3.  Activation scripts only need the log; interactive
	# APPS must also surface errors/warnings to the operator's terminal — this
	# writes to that preserved fd3, falling back to current stderr when fd3 is
	# not open (e.g. the script runs outside command:run).
	printf '%s\n' "$@" >&3 2>/dev/null || printf '%s\n' "$@" >&2
}

ndh::logger:command:invoke() {
	# ndh::logger:command:invoke <command> [args...]
	# Runs <command> as a PLAIN statement, in a subshell that keeps the caller's errexit, and leaves its
	# exit status in NDH_LOGGER_COMMAND_RC; returns 0. Never put the call in an `if`, `!`, `&&` or `||`:
	# bash ignores errexit for the WHOLE call tree of a command run there, subshells included
	# (measured, bash 5.3: `( set -e; f ) || rc=$?` runs on past f's failure). That is how this wrapper
	# used to run its command (`if "$@"`), so a `set -e` script never stopped on a failure and was
	# reported failed only when its LAST command failed (2026-09-20, 2026-09-26, 2026-10-14).
	# A script without `set -e` keeps running past a failure, as it asked. The subshell keeps the
	# command's shell state (variables, cwd) from the wrapper; what it writes to files and fds is as
	# before.
	local errexit=0
	case $- in *e*) errexit=1 ;; esac
	set +e
	(
		if [ "$errexit" = 1 ]; then set -e; fi
		"$@"
	)
	NDH_LOGGER_COMMAND_RC=$?
	if [ "$errexit" = 1 ]; then set -e; fi
	return 0
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

	# Generate a fresh marker for each command-run invocation so hints are
	# command-scoped rather than shell-scoped.
	unset NDH_LOG_RUN_MARKER NDH_LOG_RUN_MARKER_SCOPE NDH_LOG_RUN_MARKER_EMITTED
	ndh::logger:run:marker:ensure "$tag"

	ndh::logger:hints:resolve "$tag"

	# All logger diagnostics go to stderr.  The wrapped command's stdout
	# is the contract: callers like sshd's `AuthorizedKeysCommand` /
	# `AuthorizedPrincipalsCommand` parse the subprocess stdout
	# verbatim, so any logger preamble/footer leaking onto fd 1 corrupts
	# their input and breaks public-key auth.  Earlier this manifested
	# as "ED25519 key is not allowed" with sshd's debug2 output showing
	# the logger banner being processed as if it were authorized_keys
	# lines.
	{
		echo "[$tag] ndh::logger:command:starting logged command: \"${caller_src} ${*:2}\" with PID $$"
		echo "[$tag] ndh::logger:command:run marker: ${NDH_LOG_RUN_MARKER}"
		echo "[$tag] ndh::logger:command:run marker scope: ${NDH_LOG_RUN_MARKER_SCOPE:-unknown}"
		echo "[$tag] ndh::logger:command:${NDH_LOG_HINT_SHOW_LABEL}: ${NDH_LOG_HINT_SHOW_CMD}"
		echo "[$tag] ndh::logger:command:${NDH_LOG_HINT_STREAM_LABEL}: ${NDH_LOG_HINT_STREAM_CMD}"
	} >&2

	# Keep a handle to original stderr so we can always emit critical notices to
	# the invoking console, even after output redirection to logger/file sinks.
	exec 3>&2
	ndh::logger:stderr:redirect "$tag"

	# Traced by default (the operator, 2026-10-21): the system log tells the story. A trace writes every value
	# the command expands, so the lines that hold a secret sit in ndh::secret:begin/end, and a script that holds
	# them throughout opts out with NDH_LOGGER_XTRACE=0 in its whole-script guard.
	if [ "${NDH_LOGGER_XTRACE:-1}" != 0 ]; then set -x; fi
	local rc
	ndh::logger:command:invoke "$@"
	rc=$NDH_LOGGER_COMMAND_RC
	if [ "$rc" = 0 ]; then
		echo "[$tag] ndh::logger:command:run completed successfully" >&2
	else
		echo "[$tag] ndh::logger:command:run failed (rc=$rc)" >&2
		if [ -n "${ACTIVATION_LOG_FILE:-}" ]; then
			printf '[%s] ndh::logger:command:run error details: %s\n' "$tag" "${ACTIVATION_LOG_FILE}" >&3
		fi
	fi
	set +x
	return "$rc"
}
