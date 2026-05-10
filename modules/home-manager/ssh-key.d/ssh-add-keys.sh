#!/usr/bin/env -S bash -exuo pipefail
# @codebase
# Load SSH keys listed in generated keys.yaml into the ssh-agent via keychain,
# and refresh the managed block of authorized_keys from corresponding .pub files.
# Key files are extracted by the Home Manager activation extractSSHKeys step.
# This script is run by the LaunchAgent on login to ensure keys survive reboots.

# User-space HM launchd context: skip hard bootstrap profile enforcement.

# shellcheck disable=SC1091
source "@nixBashTrampoline@"

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
	local allowedCsv="@allowedKeyNamesCsv@"
	if [[ -z "$allowedCsv" ]]; then
		yq eval '.keys | keys[]' "$sshKeysYaml"
		return 0
	fi

	yq eval '.keys | keys[]' "$sshKeysYaml" \
		| awk -v csv="$allowedCsv" '
			BEGIN {
				split(csv, a, ",")
				for (i in a) {
					if (a[i] != "") allowed[a[i]] = 1
				}
			}
			{ if ($0 in allowed) print $0 }
		'
}

ndh::ssh:keys:authorized:file:ensure() {
	local authorizedKeysFile="${1:?authorized_keys path required}"
	if [[ ! -f "$authorizedKeysFile" ]]; then
		install -m 600 /dev/null "$authorizedKeysFile"
	fi
}

ndh::ssh:keys:agent:init() {
	# Initialize / attach to agent (keychain handles reuse)
	# shellcheck disable=SC1090
	if ! source <(keychain --quiet --eval 2>/dev/null); then
		source <(keychain -q --eval)
	fi
}

ndh::ssh:keys:certificate:keyid:extract() {
	local certPath="${1:?certificate path required}"
	[[ -f "$certPath" ]] || return 1
	ssh-keygen -Lf "$certPath" 2>/dev/null | awk -F': ' '/Key ID:/ { gsub(/"/, "", $2); print $2; exit }'
}

ndh::ssh:keys:certificate:is:managed() {
	local keyId="${1:-}"
	[[ -n "$keyId" ]] || return 1
	printf '%s\n' "$keyId" | yq eval -e '.marker == "ndh-ssh-key-meta-v1"' - >/dev/null 2>&1
}

ndh::ssh:keys:fingerprint:from:public:line() {
	local publicKeyLine="${1:-}"
	local tmpDir="${2:?tmp dir required}"
	local tmpPublicKey
	[[ -n "$publicKeyLine" ]] || return 1

	tmpPublicKey="$(mktemp "${tmpDir}/fp.XXXXXX.pub")"
	printf '%s\n' "$publicKeyLine" >"$tmpPublicKey"
	if ! ssh-keygen -lf "$tmpPublicKey" 2>/dev/null | awk '{print $2}'; then
		rm -f "$tmpPublicKey"
		return 1
	fi
	rm -f "$tmpPublicKey"
}

ndh::ssh:keys:managed:fingerprints:collect() {
	local keyList="${1:?key list required}"
	local keysDir="${2:?keys dir required}"
	local tmpDir="${3:?tmp dir required}"
	local outputFile="${4:?output file required}"
	: >"$outputFile"

	local keyName keyPath pubPath certPath certKeyId pubLine fingerprint
	while IFS= read -r keyName; do
		[[ -n "$keyName" ]] || continue
		keyPath="${keysDir}/${keyName}"
		pubPath="${keyPath}.pub"
		certPath="${keysDir}/${keyName}-cert.pub"
		[[ -f "$pubPath" ]] || continue
		[[ -f "$certPath" ]] || continue
		certKeyId="$(ndh::ssh:keys:certificate:keyid:extract "$certPath" || true)"
		if ! ndh::ssh:keys:certificate:is:managed "$certKeyId"; then
			continue
		fi
		pubLine="$(<"$pubPath")"
		fingerprint="$(ndh::ssh:keys:fingerprint:from:public:line "$pubLine" "$tmpDir" || true)"
		[[ -n "$fingerprint" ]] || continue
		echo "$fingerprint" >>"$outputFile"
	done <<<"$keyList"

	if [[ -s "$outputFile" ]]; then
		sort -u "$outputFile" -o "$outputFile"
	fi
}

ndh::ssh:keys:agent:managed:rotate:begin() {
	local tmpDir="${1:?tmp dir required}"
	local managedFingerprintsFile="${2:?managed fingerprints file required}"
	local index=0
	[[ -s "$managedFingerprintsFile" ]] || return 0

	while IFS= read -r publicKeyLine; do
		[[ -n "$publicKeyLine" ]] || continue
		local fingerprint
		fingerprint="$(ndh::ssh:keys:fingerprint:from:public:line "$publicKeyLine" "$tmpDir" || true)"
		if [[ -z "$fingerprint" ]] || ! grep -Fxq "$fingerprint" "$managedFingerprintsFile"; then
			continue
		fi

		local publicKeyTmp
		publicKeyTmp="${tmpDir}/agent-managed-${index}.pub"
		printf '%s\n' "$publicKeyLine" >"$publicKeyTmp"
		ssh-add -q -d "$publicKeyTmp" 2>/dev/null || true
		index=$((index + 1))
	done < <(ssh-add -L 2>/dev/null || true)
}

ndh::ssh:keys:public:line:normalize() {
	local line="${1:-}"
	[[ -n "$line" ]] || return 1

	local f1 f2 rest
	read -r f1 f2 rest <<<"$line"
	if [[ "$f1" == ssh-* && "$f2" == ssh-* ]]; then
		printf '%s %s\n' "$f1" "$rest"
		return 0
	fi

	printf '%s\n' "$line"
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
		pubPath="${keyPath}.pub"

		ssh-add -q -d "$keyPath" 2>/dev/null || true
		ssh-add "$keyPath" 2>/dev/null || true

		if [[ -f "$pubPath" ]]; then
			while IFS= read -r pubLine; do
				[[ -n "$pubLine" ]] || continue
				ndh::ssh:keys:public:line:normalize "$pubLine" >>"$generatedTmp"
			done <"$pubPath"
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
	local managedFingerprintsTmp
	managedFingerprintsTmp="${tmpDir}/managed.fingerprints"
	existingTmp="${tmpDir}/existing.authorized_keys"
	authorizedKeysNew="${tmpDir}/authorized_keys.new"
	trap 'ndh::ssh:keys:tmp:cleanup "$tmpDir"' EXIT

	# Build managed fingerprint set from generated/extracted .pub metadata using
	# yq JSON marker parsing, then rotate agent keys by fingerprint.
	ndh::ssh:keys:managed:fingerprints:collect "$keyList" "$keysDir" "$tmpDir" "$managedFingerprintsTmp"

	# Rotate managed keys in the current agent session first, then re-add
	# keys from the freshly extracted key directory.
	ndh::ssh:keys:agent:managed:rotate:begin "$tmpDir" "$managedFingerprintsTmp"

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

ndh::logger:command:run "@loggerTag@" main "$@"
