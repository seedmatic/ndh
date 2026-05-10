#!/usr/bin/env -S bash -euo pipefail

shopt -s nullglob

# Home Manager user-space activation context: do not hard-fail on missing
# root bootstrap runtime profile holder. The script's own runtime inputs are
# provided via activation wrapper/store paths.

main() {
	yamlFile="$1"
	userOutputDir="$2"
	targetUser="${3:-${USER:-}}"
	# Optional 4th arg: root-owned system path for keys whose top-level usage
	# includes `ssh-host` (split-exp target_dir="system-private"). When empty
	# we fall back to $userOutputDir so user extraction can write private keys.
	systemPrivateOutputDir="${4:-}"
	if [[ -z "$systemPrivateOutputDir" ]]; then
		systemPrivateOutputDir="$userOutputDir"
	fi
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
	: "Full wipe ensures no orphaned keys from schema migrations remain."
	rm -fr "$userOutputDir"
	# Only wipe the system-private dir when it is distinct from user output.
	if [[ "$systemPrivateOutputDir" != "$userOutputDir" ]]; then
		rm -fr "$systemPrivateOutputDir"
	fi

	# Provision split SSH key directories.
	if [[ "$(id -u)" -eq 0 && -n "$targetUser" ]]; then
		targetGroup="$(id -gn "$targetUser" 2>/dev/null || echo "$targetUser")"
		install -o "$targetUser" -g "$targetGroup" -m 0700 -d "${userOutputDir}"
	else
		install -m 0700 -d "${userOutputDir}"
	fi
	# system-private is always root-owned, regardless of who runs the script.
	# The trampoline puts GNU coreutils on PATH on both Linux and Darwin, so
	# `install -d` creates intermediate parents here.
	install -m 0700 -d "${systemPrivateOutputDir}"

	: "Use yq to generate the array, split it into files, and output to the specified directory"
	if [[ ! -r "@splitExpFile@" ]]; then
		echo "missing yq split expression file: @splitExpFile@" >&2
		exit 1
	fi
	tmpDir="$(mktemp --directory)"
	trap 'rm -fr "$tmpDir"' EXIT
	if ! env TMPDIR="$tmpDir" yq eval --from-file '@splitExpFile@' "$yamlFile" -s '.yamlfile'; then
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
		case "$targetDir" in
		system-private)
			contentFile="$systemPrivateOutputDir/$relPath"
			;;
		system)
			contentFile="$userOutputDir/$relPath"
			;;
		*)
			contentFile="$userOutputDir/$relPath"
			;;
		esac
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
				# Emit a sibling .sha256 file holding the ssh-keygen fingerprint line
				# (SHA256:... + comment + type) so it can be diff'd against `ssh-add -l`.
				ssh-keygen -lf "$contentFile" >"${contentFile%.pub}.sha256"
				chmod 644 "${contentFile%.pub}.sha256"
			fi
		else
			chmod 600 "$contentFile"
		fi

		# Keep canonical public key next to its private key.
		if [[ "$filename" == *.pub && "$filename" != *-cert.pub && "$filename" != *-ca.pub ]]; then
			if [[ "$userOutputDir/$relPath" != "$contentFile" ]]; then
				mkdir -p "$(dirname "$userOutputDir/$relPath")"
				ln -sf \
					"$(realpath --relative-to="$(dirname "$userOutputDir/$relPath")" "$contentFile")" \
					"$userOutputDir/$relPath"
			fi
		fi
	done
	rm -fr "$tmpDir"

	: "Provide stable symlink names (<key>-cert.pub) pointing to a matching user certificate."
	# Match is validated by comparing key fingerprint and certificate embedded public-key fingerprint.
	# Iterate over both private-key locations (user + system-private) so that
	# ssh-host identities get their cert symlink next to the system-scope key.
	priv_dirs=("$userOutputDir")
	if [[ "$systemPrivateOutputDir" != "$userOutputDir" ]]; then
		priv_dirs+=("$systemPrivateOutputDir")
	fi
	for priv_dir in "${priv_dirs[@]}"; do
		for priv in "$priv_dir/"*; do
			[[ -f "$priv" ]] || continue
			case "$priv" in
			*.pub) continue ;;
			*/keys.yaml) continue ;;
			esac
			base="${priv##*/}"
			user_certs=("$userOutputDir/${base}"-*-user-cert.pub)
			host_certs=("$userOutputDir/${base}"-*-host-cert.pub)

			key_fp="$(ssh-keygen -lf "$priv" 2>/dev/null | awk '{print $2}' || true)"
			if [[ -z "$key_fp" ]]; then
				rm -f "$priv_dir/${base}-cert.pub"
				rm -f "$userOutputDir/${base}-server-cert.pub"
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
				# Relative target: cert file lives in userOutputDir, link in
				# priv_dir — identical when they are the same dir, else
				# `realpath --relative-to` produces the right `../` prefix.
				ln -sf \
					"$(realpath --relative-to="$priv_dir" "$matched_user_cert")" \
					"$priv_dir/${base}-cert.pub"
			else
				rm -f "$priv_dir/${base}-cert.pub"
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
				ln -sf \
					"$(realpath --relative-to="$userOutputDir" "$matched_host_cert")" \
					"$userOutputDir/${base}-server-cert.pub"
			else
				rm -f "$userOutputDir/${base}-server-cert.pub"
			fi
		done
	done
}

# shellcheck disable=SC1091
source @nixBashTrampoline@
ndh::logger:command:run "@loggerTag@" main "$@"
