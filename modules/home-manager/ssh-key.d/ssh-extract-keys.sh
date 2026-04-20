#!/usr/bin/env -S bash -euo pipefail

shopt -s nullglob

# Home Manager user-space activation context: do not hard-fail on missing
# root bootstrap runtime profile holder. The script's own runtime inputs are
# provided via activation wrapper/store paths.
export NDH_BOOTSTRAP_STRICT=0

main() {
	yamlFile="$1"
	userOutputDir="$2"
	targetUser="${3:-${USER:-}}"
	authorityOutputDir="$userOutputDir/.authority.d"
	if [[ ! -r "$yamlFile" ]]; then
		echo "missing or unreadable generated YAML: $yamlFile" >&2
		exit 1
	fi
	if [[ ! -w "$(dirname "$userOutputDir")" ]] || [[ -e "$userOutputDir" && ! -w "$userOutputDir" ]]; then
		if [[ -x /run/wrappers/bin/sudo ]]; then
			targetGroup="$(id -gn "$targetUser" 2>/dev/null || echo "$targetUser")"
			/run/wrappers/bin/sudo -n chown -R "$targetUser:$targetGroup" "$(dirname "$userOutputDir")" 2>/dev/null || true
		fi
	fi
	if [[ "$(id -u)" -eq 0 && -n "$targetUser" && -e "$userOutputDir" ]]; then
		targetGroup="$(id -gn "$targetUser" 2>/dev/null || echo "$targetUser")"
		chown -R "$targetUser:$targetGroup" "$userOutputDir" 2>/dev/null || true
	fi

	: "Prune stale generated artifacts from previous schema/key-name variants."
	rm -fr "$userOutputDir"

	# Provision split SSH key directories.
	if [[ "$(id -u)" -eq 0 && -n "$targetUser" ]]; then
		targetGroup="$(id -gn "$targetUser" 2>/dev/null || echo "$targetUser")"
		install -o "$targetUser" -g "$targetGroup" -m 0700 -d "${userOutputDir}"
		install -o "$targetUser" -g "$targetGroup" -m 0700 -d "${authorityOutputDir}"
	else
		install -m 0700 -d "${userOutputDir}"
		install -m 0700 -d "${authorityOutputDir}"
	fi

	: "Use yq to generate the array, split it into files, and output to the specified directory"
	if [[ ! -r "@splitExpFile@" ]]; then
		echo "missing yq split expression file: @splitExpFile@" >&2
		exit 1
	fi
	exp="$(<@splitExpFile@)"
	tmpDir="$(mktemp --directory)"
	trap 'rm -fr "$tmpDir"' EXIT
	if ! env TMPDIR="$tmpDir" yq eval "$exp" "$yamlFile" -s '.yamlfile'; then
		echo "Failed to extract SSH key artifacts from $yamlFile" >&2
		exit 1
	fi

	: "Post-process to extract only the content"
	# Only touch files created by yq (*.yml split output); leave other non-YAML files untouched.
	for yamlFile in "$tmpDir"/*; do
		relPath="$(yq eval -r '.rel_path // ""' "$yamlFile")"
		if [[ -z "$relPath" ]]; then
			echo "Missing rel_path metadata in split YAML: $yamlFile" >&2
			exit 1
		fi
		targetDir="$(yq eval -r '.target_dir // "user"' "$yamlFile")"
		if [[ "$targetDir" == "system" ]]; then
			contentFile="$authorityOutputDir/$relPath"
		else
			contentFile="$userOutputDir/$relPath"
		fi
		mkdir -p "$(dirname "$contentFile")"
		mv "$yamlFile" "$contentFile"
		contentTmp="$(mktemp)"
		yq eval -r '.content' "$contentFile" >"$contentTmp"
		mv "$contentTmp" "$contentFile"
		filename="${contentFile##*/}"
		if [[ "$filename" == *.pub ]]; then
			# Cert/public key files must be exactly one line; drop any blank padding
			# introduced by YAML block scalar newline preservation.
			contentTmp="$(mktemp)"
			awk 'NF { print; exit }' "$contentFile" >"$contentTmp"
			mv "$contentTmp" "$contentFile"
			chmod 644 "$contentFile"
			if [[ "$filename" == *-cert.pub ]]; then
				ssh-keygen -Lf "$contentFile" >/dev/null
			else
				ssh-keygen -lf "$contentFile" >/dev/null
			fi
		else
			chmod 600 "$contentFile"
		fi

		# Keep canonical public key next to its private key while preserving
		# backward compatibility for consumers reading from authorityOutputDir.
		if [[ "$filename" == *.pub && "$filename" != *-cert.pub && "$filename" != *-ca.pub ]]; then
			mkdir -p "$(dirname "$authorityOutputDir/$relPath")"
			ln -sf "$contentFile" "$authorityOutputDir/$relPath"
		fi
	done
	rm -fr "$tmpDir"

	: "Provide stable symlink names (<key>-cert.pub) pointing to a matching user certificate."
	# Match is validated by comparing key fingerprint and certificate embedded public-key fingerprint.
	for priv in "$userOutputDir/"*; do
		[[ -f "$priv" ]] || continue
		case "$priv" in
		*.pub) continue ;;
		*/keys.yaml) continue ;;
		esac
		base="${priv##*/}"
		user_certs=("$authorityOutputDir/${base}"-*-user-cert.pub)
		host_certs=("$authorityOutputDir/${base}"-*-host-cert.pub)

		key_fp="$(ssh-keygen -lf "$priv" 2>/dev/null | awk '{print $2}' || true)"
		if [[ -z "$key_fp" ]]; then
			rm -f "$userOutputDir/${base}-cert.pub"
			rm -f "$authorityOutputDir/${base}-server-cert.pub"
			continue
		fi

		matched_user_cert=""
		for cert in "${user_certs[@]}"; do
			[[ -f "$cert" ]] || continue
			cert_fp="$(ssh-keygen -Lf "$cert" 2>/dev/null | awk '/Public key:/ {print $4; exit}' || true)"
			if [[ -n "$cert_fp" && "$cert_fp" == "$key_fp" ]]; then
				matched_user_cert="$cert"
				break
			fi
		done

		if [[ -n "$matched_user_cert" ]]; then
			ln -sf "$matched_user_cert" "$userOutputDir/${base}-cert.pub"
		else
			rm -f "$userOutputDir/${base}-cert.pub"
		fi

		matched_host_cert=""
		for cert in "${host_certs[@]}"; do
			[[ -f "$cert" ]] || continue
			cert_fp="$(ssh-keygen -Lf "$cert" 2>/dev/null | awk '/Public key:/ {print $4; exit}' || true)"
			cert_kind="$(ssh-keygen -Lf "$cert" 2>/dev/null | awk '/Type:/ { if ($0 ~ / host certificate$/) { print "host" } else { print "other" }; exit }' || true)"
			if [[ "$cert_kind" == "host" && -n "$cert_fp" && "$cert_fp" == "$key_fp" ]]; then
				matched_host_cert="$cert"
				break
			fi
		done

		if [[ -n "$matched_host_cert" ]]; then
			ln -sf "$matched_host_cert" "$authorityOutputDir/${base}-server-cert.pub"
		else
			rm -f "$authorityOutputDir/${base}-server-cert.pub"
		fi
	done
}

# shellcheck disable=SC1091
source @bashTrampoline@
# shellcheck disable=SC1091
source @logger@
ndh::logger:command:run "@loggerTag@" main "$@"
