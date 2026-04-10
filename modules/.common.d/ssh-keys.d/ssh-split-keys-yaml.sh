#!/usr/bin/env -S bash -euo pipefail
# @codebase
# Split generated SSH keys YAML into system and profile scopes.

# shellcheck disable=SC1091
source @bashTrampoline@
# shellcheck disable=SC1091
source @logger@

main() {
	local generatedKeysYamlPath="${1:?generated keys yaml path required}"
	local generatedSystemKeysYamlPath="${2:?generated system keys yaml path required}"
	local generatedProfileKeysYamlPath="${3:?generated profile keys yaml path required}"
	local profileOwnerName="${4:?profile owner name required}"

	if ! command -v yq >/dev/null 2>&1; then
		echo "missing required binary in PATH: yq" >&2
		return 1
	fi
	if [[ ! -r "$generatedKeysYamlPath" ]]; then
		echo "missing generated keys YAML: $generatedKeysYamlPath" >&2
		return 1
	fi

	install -d -m 0755 "$(dirname "$generatedSystemKeysYamlPath")" "$(dirname "$generatedProfileKeysYamlPath")"

	# System split: keep host/system-signing material.
	yq eval -o=yaml '
	  .keys |= with_entries(
	    select(
	      ((.value.usage // []) | map(select(. == "ssh-authority" or . == "ssh-host" or . == "host-signing")) | length > 0)
	    )
	  )
	' "$generatedKeysYamlPath" >"$generatedSystemKeysYamlPath"
	install -m 0400 "$generatedSystemKeysYamlPath" "$generatedSystemKeysYamlPath.tmp"
	mv "$generatedSystemKeysYamlPath.tmp" "$generatedSystemKeysYamlPath"
	chown root:wheel "$generatedSystemKeysYamlPath" 2>/dev/null || chown root:root "$generatedSystemKeysYamlPath" || true

	# User split: keep user signing material (and default non-system keys).
	yq eval -o=yaml '
	  .keys |= with_entries(
	    select(
	      ((.value.usage // []) | map(select(. == "ssh-authority" or . == "ssh-host" or . == "host-signing")) | length == 0)
	    )
	  )
	' "$generatedKeysYamlPath" >"$generatedProfileKeysYamlPath"
	install -m 0440 "$generatedProfileKeysYamlPath" "$generatedProfileKeysYamlPath.tmp"
	mv "$generatedProfileKeysYamlPath.tmp" "$generatedProfileKeysYamlPath"
	chown "$profileOwnerName:staff" "$generatedProfileKeysYamlPath" 2>/dev/null || chown "$profileOwnerName:wheel" "$generatedProfileKeysYamlPath" 2>/dev/null || chown "$profileOwnerName:users" "$generatedProfileKeysYamlPath" 2>/dev/null || true
}

ndh::logger:command:run "@loggerTag@" main "$@"
