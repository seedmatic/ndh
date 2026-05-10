#!/usr/bin/env -S bash -euo pipefail
# @codebase
# Split enriched SSH keys YAML (v2) into scope-specific files.
#
# In v2 each key declares `profiles: [bringup, host, user, ...]`. This
# script emits:
#
#   <generatedSystemKeysYamlPath>  — keys with `host` in .profiles
#   <generatedProfileKeysYamlPath> — keys with <profileName> in .profiles
#
# Both outputs carry the full `.authorities` block (small; every consumer
# needs it to validate cert chains). If you want finer splits later, add
# more output slots; the caller owns the path naming.
#
# Commit 3 will restructure the caller to pass a list of (profile,path)
# pairs so the same splitter can emit arbitrary per-profile files. For
# now the two-slot API preserves the existing caller.

# shellcheck disable=SC1091
source @nixBashTrampoline@

main() {
	local generatedKeysYamlPath="${1:?generated keys yaml path required}"
	local generatedSystemKeysYamlPath="${2:?generated system keys yaml path required}"
	local generatedProfileKeysYamlPath="${3:?generated profile keys yaml path required}"
	local profileOwnerName="${4:?profile owner name required}"
	local profileName="${5:-}"

	if ! command -v yq >/dev/null 2>&1; then
		echo "missing required binary in PATH: yq" >&2
		return 1
	fi
	if [[ ! -r "$generatedKeysYamlPath" ]]; then
		echo "missing generated keys YAML: $generatedKeysYamlPath" >&2
		return 1
	fi

	# Derive profile name from the output path if the caller did not
	# supply one explicitly. The legacy API left profile name implicit
	# in the path, e.g. profiles/user.yaml → "user".
	if [[ -z "$profileName" ]]; then
		local base
		base="$(basename "$generatedProfileKeysYamlPath")"
		profileName="${base%.yaml}"
	fi

	install -d -m 0755 \
		"$(dirname "$generatedSystemKeysYamlPath")" \
		"$(dirname "$generatedProfileKeysYamlPath")"

	# System scope: keys whose .profiles includes "system". Carries the full
	# .authorities block so consumers can validate cert chains.
	yq eval -o=yaml "
		.keys |= with_entries(
			select(
				((.value.profiles // []) | map(select(. == \"system\")) | length > 0)
			)
		)
	" "$generatedKeysYamlPath" >"$generatedSystemKeysYamlPath"
	install -m 0400 "$generatedSystemKeysYamlPath" "$generatedSystemKeysYamlPath.tmp"
	mv "$generatedSystemKeysYamlPath.tmp" "$generatedSystemKeysYamlPath"
	chown root:wheel "$generatedSystemKeysYamlPath" 2>/dev/null \
		|| chown root:root "$generatedSystemKeysYamlPath" \
		|| true

	# Profile scope: keys whose .profiles includes the named profile.
	# Same shape as system scope, just a different membership predicate.
	env PROFILE="$profileName" yq eval -o=yaml '
		.keys |= with_entries(
			select(
				((.value.profiles // []) | map(select(. == strenv(PROFILE))) | length > 0)
			)
		)
	' "$generatedKeysYamlPath" >"$generatedProfileKeysYamlPath"
	install -m 0440 "$generatedProfileKeysYamlPath" "$generatedProfileKeysYamlPath.tmp"
	mv "$generatedProfileKeysYamlPath.tmp" "$generatedProfileKeysYamlPath"
	chown "$profileOwnerName:staff" "$generatedProfileKeysYamlPath" 2>/dev/null \
		|| chown "$profileOwnerName:wheel" "$generatedProfileKeysYamlPath" 2>/dev/null \
		|| chown "$profileOwnerName:users" "$generatedProfileKeysYamlPath" 2>/dev/null \
		|| true
}

ndh::logger:command:run "@loggerTag@" main "$@"
