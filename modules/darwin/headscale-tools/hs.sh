# @codebase hs — fleet headscale admin CLI.
#
# Single binary with git-style subcommands.  The `writeShellApplication`
# wrapper runs shellcheck over the whole script at build time.
#
# Subcommands:
#   hs check                    Read-only reconcile between `.secrets`
#                               and the live headscale server.  Runs
#                               from every Darwin activation
#                               (timeout-capped, warn-only).
#   hs mint [...]               Operator-only: mint missing per-kind
#                               preauth keys and write them back into
#                               `.secrets`.  Never runs automatically.
#
# Anything else is forwarded to the `headscale` CLI with the right
# transport: local unix socket on the primary host (no API key
# needed), gRPC-over-env on every other host.  So `hs nodes list`,
# `hs preauthkeys list`, etc. Just Work.
#
# @HS_LIB_INLINE@

API_KEY_FILE="@API_KEY_FILE@"
HEADSCALE_HOSTNAME="@HEADSCALE_HOSTNAME@"
EXPECTED_USER="@EXPECTED_USER@"
MINT_EXPIRATION="@MINT_EXPIRATION@"

# `.secrets` lives in the operator's worktree — NOT in the nix-store
# snapshot of the flake (that's read-only and gets purged on GC).
# Resolve at runtime from the current cwd via `git rev-parse
# --show-toplevel`; fall back to NDH_SECRETS_FILE when set (handy
# for out-of-tree invocations and tests).
hs::secrets_file() {
	if [ -n "${NDH_SECRETS_FILE:-}" ]; then
		printf '%s\n' "$NDH_SECRETS_FILE"
		return 0
	fi
	local top
	if top="$(git rev-parse --show-toplevel 2>/dev/null)" && [ -n "$top" ]; then
		printf '%s/.secrets\n' "$top"
		return 0
	fi
	log::error "not in a git worktree and NDH_SECRETS_FILE unset; cannot locate .secrets"
	return 1
}

# All the kinds the .secrets schema knows about.  Must stay in sync
# with modules/.common.d/tailnet.nix's headscaleAuthKinds and with
# catalog/headscale/acl.hujson's tagOwners block.
declare -ga HS_KINDS=(darwin nixos incus rke2)

# ---------------------------------------------------------------------
# Transport envelope — local unix socket vs remote gRPC.
# ---------------------------------------------------------------------

# hs::headscale runs the headscale CLI with auto-detected transport.
# On the primary host (~/.config/headscale/config.yaml exists) the
# unix socket path is used; elsewhere HEADSCALE_CLI_* env vars are
# exported so the CLI hits the gRPC endpoint.  Consumers that want a
# specific HEADSCALE_CLI_ADDRESS override pass it via the caller's
# environment.
hs::headscale() {
	local cfg
	cfg="$(hs::config::path)"
	if [ -n "$cfg" ]; then
		headscale -c "$cfg" "$@"
		return
	fi

	if [ ! -r "$API_KEY_FILE" ]; then
		log::error "no local headscale config and API key not readable at $API_KEY_FILE"
		return 1
	fi
	: "${HEADSCALE_CLI_ADDRESS:=${HEADSCALE_HOSTNAME}:50443}"
	export HEADSCALE_CLI_ADDRESS
	HEADSCALE_CLI_API_KEY="$(tr -d '[:space:]' <"$API_KEY_FILE")"
	export HEADSCALE_CLI_API_KEY
	headscale "$@"
}

# Expected tag pair per kind.  Must stay in sync with
# catalog/headscale/acl.hujson (the `console` / `headless` vocabulary
# defined there).
hs::kind::tags() {
	local kind="$1"
	case "$kind" in
		darwin) printf 'tag:console,tag:darwin' ;;
		nixos | incus | rke2) printf 'tag:headless,tag:%s' "$kind" ;;
		*)
			log::error "unknown kind: $kind"
			return 1
			;;
	esac
}

# Canonical form: sorted + unique, comma-joined.  Lets us compare
# two tag lists for semantic equality regardless of input order.
hs::tags::canonical() {
	printf '%s' "$1" | tr ',' '\n' | sort -u | paste -sd, -
}

# ---------------------------------------------------------------------
# Subcommand: check
# ---------------------------------------------------------------------

hs::check::server_reachable() {
	if ! hs::headscale version >/dev/null 2>&1; then
		log::error "headscale unreachable or unauthenticated"
		return 1
	fi
}

hs::check::user_exists() {
	local found
	found="$(hs::headscale users list --output json 2>/dev/null |
		yq eval -r ".[] | select(.name == \"${EXPECTED_USER}\") | .id" - 2>/dev/null)"
	if [ -z "$found" ]; then
		log::warn "user ${EXPECTED_USER} missing server-side; run 'hs users create ${EXPECTED_USER}'"
	fi
}

hs::check::preauth_keys() {
	local sops_file="$1"
	local server_keys
	server_keys="$(hs::headscale preauthkeys list --output json 2>/dev/null)"
	if [ -z "$server_keys" ]; then
		log::warn "no preauth keys on server"
		return 0
	fi

	local kind secret_key server_entry server_tags_csv
	local expected_tags expected_canonical actual_canonical
	for kind in "${HS_KINDS[@]}"; do
		secret_key="$(sops::edit::get_string "$sops_file" \
			".tailnet.headscale.auth.${kind}" 2>/dev/null)"

		if [ -z "$secret_key" ] || [ "$secret_key" = "null" ]; then
			# Empty slot is fine — only the kinds actually in use
			# need to be filled.
			continue
		fi

		server_entry="$(printf '%s' "$server_keys" |
			yq eval -r ".[] | select(.key == \"${secret_key}\") | .id" - 2>/dev/null)"

		if [ -z "$server_entry" ]; then
			log::warn "auth.${kind} in .secrets has no matching preauth key on server (stale; run 'hs mint --force ${kind}')"
			continue
		fi

		# Verify the server's acl-tags match what this kind is
		# supposed to register as.  Catches the case where the
		# vocabulary was renamed (operator→console, service→headless)
		# but the existing preauth key still carries the old tags —
		# registering with it would produce a node tagged under the
		# old scheme, which the new ACL doesn't grant anything to.
		server_tags_csv="$(printf '%s' "$server_keys" |
			yq eval -r ".[] | select(.key == \"${secret_key}\") | .aclTags | join(\",\")" - 2>/dev/null)"
		expected_tags="$(hs::kind::tags "$kind")" || continue
		expected_canonical="$(hs::tags::canonical "$expected_tags")"
		actual_canonical="$(hs::tags::canonical "$server_tags_csv")"
		if [ "$expected_canonical" != "$actual_canonical" ]; then
			log::warn "auth.${kind} server tags [${actual_canonical}] disagree with expected [${expected_canonical}] (run 'hs mint --force ${kind}')"
		fi
	done
}

hs::cmd::check() {
	local sops_file
	sops_file="$(hs::secrets_file)" || return 1
	if [ ! -r "$sops_file" ]; then
		log::error "sops file not readable at $sops_file"
		return 1
	fi
	hs::check::server_reachable || return 1
	hs::check::user_exists
	hs::check::preauth_keys "$sops_file"
	log::info "reconcile check complete"
}

# ---------------------------------------------------------------------
# Subcommand: mint
# ---------------------------------------------------------------------

hs::mint::ensure_user() {
	local uid
	uid="$(hs::headscale users list --output json 2>/dev/null |
		yq eval -r ".[] | select(.name == \"${EXPECTED_USER}\") | .id" - 2>/dev/null)"
	if [ -n "$uid" ]; then
		printf '%s\n' "$uid"
		return 0
	fi

	log::info "creating user ${EXPECTED_USER}"
	hs::headscale users create "$EXPECTED_USER" >/dev/null
	hs::headscale users list --output json |
		yq eval -r ".[] | select(.name == \"${EXPECTED_USER}\") | .id" -
}

hs::mint::key_for_kind() {
	local kind="$1" user_id="$2" tags key
	tags="$(hs::kind::tags "$kind")" || return 1

	log::info "minting preauth key for kind=${kind} tags=${tags}"
	key="$(hs::headscale preauthkeys create \
		--user "$user_id" \
		--reusable \
		--expiration "$MINT_EXPIRATION" \
		--tags "$tags" \
		--output json |
		yq eval -r '.key' -)"

	if [ -z "$key" ] || [ "$key" = "null" ]; then
		log::error "mint failed for kind=${kind}"
		return 1
	fi

	printf '%s\n' "$key"
}

# Returns 0 iff the slot already holds a key that exists on the
# server AND has the tag pair this kind expects.  Drift on either
# axis is treated as "not live" so mint rewrites the slot.
hs::mint::slot_is_live() {
	local kind="$1" server_keys="$2" sops_file="$3"
	local current
	current="$(sops::edit::get_string "$sops_file" \
		".tailnet.headscale.auth.${kind}" 2>/dev/null)"
	[ -n "$current" ] && [ "$current" != "null" ] || return 1

	local server_entry
	server_entry="$(printf '%s' "$server_keys" |
		yq eval -r ".[] | select(.key == \"${current}\") | .id" - 2>/dev/null)"
	[ -n "$server_entry" ] || return 1

	# Tag pair must match too.
	local actual_tags_csv expected_tags expected_canonical actual_canonical
	actual_tags_csv="$(printf '%s' "$server_keys" |
		yq eval -r ".[] | select(.key == \"${current}\") | .aclTags | join(\",\")" - 2>/dev/null)"
	expected_tags="$(hs::kind::tags "$kind")" || return 1
	expected_canonical="$(hs::tags::canonical "$expected_tags")"
	actual_canonical="$(hs::tags::canonical "$actual_tags_csv")"
	[ "$expected_canonical" = "$actual_canonical" ]
}

hs::mint::usage() {
	cat >&2 <<-EOF
		usage: hs mint [--force] <kind>...
		       hs mint [--force] --all

		Mint preauth keys for the named kinds and write them into
		.tailnet.headscale.auth.<kind> within the operator's .secrets
		(resolved from git worktree root; override via NDH_SECRETS_FILE).

		Kinds: ${HS_KINDS[*]}

		Without --force, a slot that already holds a live key with
		the expected tags is left untouched.  Drift on either bearer
		string or tags is treated as "needs re-mint".
	EOF
}

hs::cmd::mint() {
	local force=false all=false
	local -a wanted=()

	while [ $# -gt 0 ]; do
		case "$1" in
			--force) force=true ;;
			--all) all=true ;;
			-h | --help)
				hs::mint::usage
				return 0
				;;
			--*)
				log::error "unknown flag: $1"
				hs::mint::usage
				return 64
				;;
			*) wanted+=("$1") ;;
		esac
		shift
	done

	if $all; then
		wanted=("${HS_KINDS[@]}")
	fi
	if [ "${#wanted[@]}" -eq 0 ]; then
		hs::mint::usage
		return 64
	fi

	local sops_file
	sops_file="$(hs::secrets_file)" || return 1
	if [ ! -r "$sops_file" ]; then
		log::error "sops file not readable at $sops_file"
		return 1
	fi
	# The operator's .secrets lives in the worktree — we write back
	# to the mutable file, not the nix-store snapshot.  Guard against
	# an accidental invocation against /nix/store/...-source/.secrets
	# (which would fail with "Permission denied" later anyway).
	case "$sops_file" in
		/nix/store/*)
			log::error "refusing to write into the nix-store snapshot ($sops_file); run from the flake worktree"
			return 1
			;;
	esac

	local user_id
	user_id="$(hs::mint::ensure_user)"
	if [ -z "$user_id" ]; then
		log::error "could not resolve user id for ${EXPECTED_USER}"
		return 1
	fi

	local server_keys
	server_keys="$(hs::headscale preauthkeys list --output json 2>/dev/null || printf '[]')"

	local kind new_key
	for kind in "${wanted[@]}"; do
		if ! $force && hs::mint::slot_is_live "$kind" "$server_keys" "$sops_file"; then
			log::info "auth.${kind}: already live with expected tags, skipping (pass --force to overwrite)"
			continue
		fi

		new_key="$(hs::mint::key_for_kind "$kind" "$user_id")" || return 1
		sops::edit::set_string "$sops_file" \
			".tailnet.headscale.auth.${kind}" "$new_key" || return 1
		log::info "auth.${kind}: minted and written"
	done

	log::info "done; commit $sops_file when ready"
}

# ---------------------------------------------------------------------
# Dispatcher
# ---------------------------------------------------------------------

hs::usage() {
	cat >&2 <<-EOF
		usage: hs <subcommand> [args...]

		Fleet subcommands:
		  check                  read-only reconcile between .secrets and the server
		  mint [--force] ...     mint missing per-kind preauth keys into .secrets

		Any other arg list is forwarded to the headscale CLI with the
		right admin transport (local unix socket on the primary host,
		gRPC-over-env otherwise).  E.g.:
		  hs nodes list
		  hs users list
		  hs apikeys list
	EOF
}

main() {
	if [ $# -eq 0 ]; then
		hs::usage
		return 64
	fi

	case "$1" in
		check)
			shift
			hs::cmd::check "$@"
			;;
		mint)
			shift
			hs::cmd::mint "$@"
			;;
		-h | --help | help)
			hs::usage
			;;
		*)
			# Forward to headscale with the admin transport.
			hs::headscale "$@"
			;;
	esac
}

main "$@"
