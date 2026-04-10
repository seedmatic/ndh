#!/usr/bin/env -S bash -euo pipefail
# @codebase
# Shared orchestrator for system-side SSH keys processing:
# 1) enrich generated runtime YAML
# 2) split into system/profile YAML
# 3) optionally ensure linux-builder authorized_keys entry (NixOS)

# shellcheck disable=SC1091
source @bashTrampoline@
# shellcheck disable=SC1091
source @logger@

main() {
	local bashBin="${1:?bash binary path required}"
	local enrichScript="${2:?enrich script path required}"
	local splitScript="${3:?split script path required}"
	local sshKeyProfileName="${4:?ssh key profile name required}"
	local hostIdent="${5:?host ident required}"
	local decryptedSSHKeysYamlPath="${6:?decrypted ssh keys yaml path required}"
	local generatedKeysYamlPath="${7:?generated keys yaml path required}"
	local hostsCatalogCsv="${8:-}"
	local profileOwnerName="${9:?profile owner name required}"
	local splitKeysDir="${10:?split keys dir required}"
	local generatedSystemKeysYamlPath="${11:?generated system keys yaml path required}"
	local generatedProfileKeysYamlPath="${12:?generated profile keys yaml path required}"
	local authorizedKeysDir="${13:-}"
	local profileUserName="${14:-}"

	if [[ ! -x "$bashBin" ]]; then
		echo "missing executable bash binary: $bashBin" >&2
		return 1
	fi
	if [[ ! -r "$decryptedSSHKeysYamlPath" ]]; then
		echo "[ssh-keys-enrichment] missing decrypted SSH keys YAML: $decryptedSSHKeysYamlPath" >&2
		return 1
	fi

	local split_dir profiles_dir
	split_dir="$splitKeysDir"
	profiles_dir="$split_dir/profiles"
	install -d -m 0755 "$split_dir" "$profiles_dir"

	"$bashBin" "$enrichScript" \
		"$sshKeyProfileName" \
		"$hostIdent" \
		"$decryptedSSHKeysYamlPath" \
		"$generatedKeysYamlPath" \
		"$hostsCatalogCsv" \
		"$profileOwnerName"

	"$bashBin" "$splitScript" \
		"$generatedKeysYamlPath" \
		"$generatedSystemKeysYamlPath" \
		"$generatedProfileKeysYamlPath" \
		"$profileOwnerName"

	echo "[ssh-keys-enrichment] generated runtime keys YAML: $generatedKeysYamlPath"
	echo "[ssh-keys-enrichment] split system keys YAML: $generatedSystemKeysYamlPath"
	echo "[ssh-keys-enrichment] split profile keys YAML: $generatedProfileKeysYamlPath"

	# Optional NixOS-specific authorized_keys sync.
	if [[ -n "$authorizedKeysDir" && -n "$profileUserName" ]]; then
		local key_type key_public key_comment
		key_type="$(yq -r '.keys."linux-builder".public // "" | split(" ") | .[0] // ""' "$generatedKeysYamlPath")"
		key_public="$(yq -r '.keys."linux-builder".public // "" | split(" ") | .[1] // ""' "$generatedKeysYamlPath")"
		key_comment="$(yq -r '.keys."linux-builder".public // "" | split(" ") | .[2] // ""' "$generatedKeysYamlPath")"

		if [[ -z "$key_type" ]]; then
			key_type="ssh-ed25519"
		fi
		if [[ -z "$key_comment" ]]; then
			key_comment="linux-builder@mammoth-skate"
		fi
		if [[ -z "$key_public" ]]; then
			echo "[ssh-keys-enrichment][ERROR] missing linux-builder public key in $generatedKeysYamlPath" >&2
			return 1
		fi

		local auth_file line
		auth_file="$authorizedKeysDir/$profileUserName"
		install -d -m 0755 "$authorizedKeysDir"
		touch "$auth_file"
		chmod 0644 "$auth_file"
		chown root:root "$auth_file"

		line="$key_type $key_public $key_comment"
		if ! grep -Fqx "$line" "$auth_file"; then
			printf '%s\n' "$line" >>"$auth_file"
		fi

		awk 'NF > 0' "$auth_file" | awk '!seen[$0]++' >"$auth_file.tmp"
		install -m 0644 "$auth_file.tmp" "$auth_file"
		chown root:root "$auth_file"
		rm -f "$auth_file.tmp"

		echo "[ssh-keys-enrichment] ensured linux-builder key in $auth_file"
	fi
}

ndh::logger:command:run "@loggerTag@" main "$@"
