#!/usr/bin/env -S bash -exuo pipefail
# @codebase
# Load SSH keys listed in generated keys.yaml into the ssh-agent via keychain,
# and refresh the managed block of authorized_keys from corresponding .pub files.
# Key files are extracted by the Home Manager activation extractSSHKeys step.
# This script is run by the LaunchAgent on login to ensure keys survive reboots.

# shellcheck disable=SC1091
source "@bashTrampoline@"
# shellcheck disable=SC1091
source "@logger@"

if command -v logger >/dev/null 2>&1; then
	LOGGER_CMD="${LOGGER_CMD:-logger -t %TAG%}"
fi

ndh::ssh:keys:tmp:cleanup() {
	local tmpDir="${1:-}"
	[[ -n "$tmpDir" ]] || return 0
	rm -rf "$tmpDir" 2>/dev/null || true
}

ndh::ssh:keys:list:extract() {
	local sshKeysYaml="${1:?SSH keys YAML file required}"
	yq eval '.keys | keys[]' "$sshKeysYaml"
}

ndh::ssh:keys:authorized:file:ensure() {
	local authorizedKeysFile="${1:?authorized_keys path required}"
	if [[ ! -f "$authorizedKeysFile" ]]; then
		install -m 600 /dev/null "$authorizedKeysFile"
	fi
}

ndh::ssh:keys:agent:init() {
	# Initialize / attach to agent (keychain handles reuse)
	source <(keychain -q ${KEYCHAIN_FLAGS:---noask --nogui} --eval)
}

ndh::ssh:keys:public:collect() {
	local keyList="${1:?key list required}"
	local keysDir="${2:?keys dir required}"
	local generatedTmp="${3:?generated tmp path required}"

	local keyName keyPath pubPath
	while IFS= read -r keyName; do
		[[ -n "$keyName" ]] || continue
		[[ "$keyName" == \#* ]] && continue
		keyPath="${keysDir}/${keyName}"
		[[ -f "$keyPath" ]] || {
			echo "Warning: key not found: $keyPath" >&2
			continue
		}

		ssh-add -q -d "$keyPath" 2>/dev/null || true
		ssh-add "$keyPath" 2>/dev/null || true

		pubPath="${keyPath}.pub"
		if [[ -f "$pubPath" ]]; then
			cat "$pubPath" >>"$generatedTmp"
		fi
	done <<<"$keyList"
}

ndh::ssh:keys:public:dedup() {
	local generatedTmp="${1:?generated tmp path required}"
	local dedupTmp="${2:?dedup tmp path required}"
	if [[ -s "$generatedTmp" ]]; then
		awk '!seen[$0]++' "$generatedTmp" >"$dedupTmp" && mv "$dedupTmp" "$generatedTmp"
	fi
}

ndh::ssh:keys:authorized:managed:block:strip() {
	local authorizedKeysFile="${1:?authorized_keys path required}"
	local markBegin="${2:?mark begin required}"
	local markEnd="${3:?mark end required}"
	local existingTmp="${4:?existing tmp path required}"

	if grep -q "${markBegin}" "$authorizedKeysFile"; then
		awk -v b="${markBegin}" -v e="${markEnd}" 'BEGIN{skip=0} {
    if ($0==b){skip=1; next} if ($0==e){skip=0; next} if (!skip) print $0
  }' "$authorizedKeysFile" >"$existingTmp"
	else
		cat "$authorizedKeysFile" >"$existingTmp"
	fi
}

ndh::ssh:keys:authorized:write() {
	local existingTmp="${1:?existing tmp path required}"
	local generatedTmp="${2:?generated tmp path required}"
	local authorizedKeysFile="${3:?authorized_keys path required}"
	local authorizedKeysNew="${4:?authorized_keys temp path required}"
	local sshKeysYaml="${5:?ssh keys yaml path required}"
	local markBegin="${6:?mark begin required}"
	local markEnd="${7:?mark end required}"

	{
		cat "$existingTmp"
		echo "$markBegin"
		echo "# Managed public keys from: $sshKeysYaml"
		if [[ -s "$generatedTmp" ]]; then
			cat "$generatedTmp"
		else
			echo "# (none)"
		fi
		echo "$markEnd"
	} >"$authorizedKeysNew"

	mv "$authorizedKeysNew" "$authorizedKeysFile"
	chmod 600 "$authorizedKeysFile"
}

main() {
	local sshKeysYaml="${1:?SSH keys YAML file required}"
	local keysDir="${sshKeysYaml%.yaml}"
	local authorizedKeysFile="${HOME}/.ssh/authorized_keys"
	local markBegin="# >>> managed-by: ssh-add-keys BEGIN >>>"
	local markEnd="# <<< managed-by: ssh-add-keys END <<<"

	local keyList
	keyList="$(ndh::ssh:keys:list:extract "$sshKeysYaml")"

	ndh::ssh:keys:authorized:file:ensure "$authorizedKeysFile"

	if [[ -z "$keyList" ]]; then
		echo "No keys found in $sshKeysYaml; run home-manager activation first." >&2
		return 0
	fi

	ndh::ssh:keys:agent:init

	local tmpDir generatedTmp dedupTmp existingTmp authorizedKeysNew
	tmpDir="$(mktemp -d)"
	generatedTmp="${tmpDir}/generated.pubkeys"
	dedupTmp="${tmpDir}/generated.pubkeys.dedup"
	existingTmp="${tmpDir}/existing.authorized_keys"
	authorizedKeysNew="${tmpDir}/authorized_keys.new"
	trap "ndh::ssh:keys:tmp:cleanup '$tmpDir'" EXIT

	ndh::ssh:keys:public:collect "$keyList" "$keysDir" "$generatedTmp"
	ndh::ssh:keys:public:dedup "$generatedTmp" "$dedupTmp"
	ndh::ssh:keys:authorized:managed:block:strip "$authorizedKeysFile" "$markBegin" "$markEnd" "$existingTmp"
	ndh::ssh:keys:authorized:write \
		"$existingTmp" \
		"$generatedTmp" \
		"$authorizedKeysFile" \
		"$authorizedKeysNew" \
		"$sshKeysYaml" \
		"$markBegin" \
		"$markEnd"
}

ndh::logger:command:run home-manager.ssh-add-keys main "$@"
