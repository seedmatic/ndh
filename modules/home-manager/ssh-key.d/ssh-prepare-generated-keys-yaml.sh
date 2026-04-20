#!/usr/bin/env -S bash -euo pipefail

main() {
	effectiveSSHKeysYamlPath="@effectiveSSHKeysYamlPath@"
	systemNamespaceDir="@systemNamespaceDir@"
	systemSplitProfileKeysYamlPath="@systemSplitProfileKeysYamlPath@"
	alternateSystemSplitProfileKeysYamlPath="@alternateSystemSplitProfileKeysYamlPath@"
	runtimeSSHKeysYamlPath="@runtimeSSHKeysYamlPath@"
	alternateRuntimeSSHKeysYamlPath="@alternateRuntimeSSHKeysYamlPath@"
	sshKeyProfileName="@sshKeyProfileName@"
	hostIdent="@hostIdent@"
	hostsCatalogCsv="@hostsCatalogCsv@"
	userName="@userName@"
	sourceProfileKeysYamlPath="@sourceProfileKeysYamlPath@"

	install -m 0700 -d "$(dirname "$effectiveSSHKeysYamlPath")"
	install -m 0700 -d "$systemNamespaceDir" "$(dirname "$alternateSystemSplitProfileKeysYamlPath")"

	selected_split_yaml=""
	if [[ -r "$systemSplitProfileKeysYamlPath" ]]; then
		selected_split_yaml="$systemSplitProfileKeysYamlPath"
	elif [[ -r "$alternateSystemSplitProfileKeysYamlPath" ]]; then
		selected_split_yaml="$alternateSystemSplitProfileKeysYamlPath"
	fi

	if [[ -n "$selected_split_yaml" ]]; then
		install -m 0400 "$selected_split_yaml" "$effectiveSSHKeysYamlPath"
	else
		echo "missing system-generated profile keys YAML: $systemSplitProfileKeysYamlPath" >&2
		echo "missing user-system split profile keys YAML: $alternateSystemSplitProfileKeysYamlPath" >&2
		echo "profile.name=work sshKeyProfileName=$sshKeyProfileName" >&2
		echo "[ssh-keys][WARN] replaying system enrich/split pipeline in Home Manager context" >&2

		selected_runtime_yaml=""
		if [[ -r "$runtimeSSHKeysYamlPath" ]]; then
			selected_runtime_yaml="$runtimeSSHKeysYamlPath"
		elif [[ -r "$alternateRuntimeSSHKeysYamlPath" ]]; then
			selected_runtime_yaml="$alternateRuntimeSSHKeysYamlPath"
		fi

		if [[ -z "$selected_runtime_yaml" ]]; then
			age_key_file="${SOPS_AGE_KEY_FILE:-}"
			if [[ -z "$age_key_file" ]]; then
				for candidate in \
					"$HOME/.config/sops/age/keys.txt" \
					"/Users/$userName/.config/sops/age/keys.txt" \
					"$HOME/Private/sops:age:keys.txt"; do
					if [[ -r "$candidate" ]]; then
						age_key_file="$candidate"
						break
					fi
				done
			fi

			if [[ -n "$age_key_file" && -r "$age_key_file" ]]; then
				echo "[ssh-keys][WARN] runtime decrypted YAML missing; decrypting canonical source via sops using age key: $age_key_file" >&2
				if SOPS_AGE_KEY_FILE="$age_key_file" "@sops@" --decrypt --output-type yaml "$sourceProfileKeysYamlPath" > "$alternateRuntimeSSHKeysYamlPath.tmp"; then
					install -m 0400 "$alternateRuntimeSSHKeysYamlPath.tmp" "$alternateRuntimeSSHKeysYamlPath"
					rm -f "$alternateRuntimeSSHKeysYamlPath.tmp"
					selected_runtime_yaml="$alternateRuntimeSSHKeysYamlPath"
				else
					rm -f "$alternateRuntimeSSHKeysYamlPath.tmp"
					echo "[ssh-keys][WARN] sops decrypt fallback failed for $sourceProfileKeysYamlPath" >&2
				fi
			fi
		fi

		if [[ -z "$selected_runtime_yaml" ]]; then
			echo "[ssh-keys][ERROR] missing runtime decrypted SSH keys YAML: $runtimeSSHKeysYamlPath" >&2
			echo "[ssh-keys][ERROR] missing alternate runtime decrypted SSH keys YAML: $alternateRuntimeSSHKeysYamlPath" >&2
			echo "[ssh-keys][ERROR] missing usable age key for sops fallback decrypt" >&2
			echo "[ssh-keys][HINT] ensure sops secret materialization is available before HM activation" >&2
			exit 1
		fi

		tmp_split_dir="$(mktemp -d)"
		generated_keys_yaml="$tmp_split_dir/keys.generated.yaml"
		generated_system_yaml="$tmp_split_dir/system.yaml"
		generated_profile_yaml="$tmp_split_dir/profile.yaml"

		"@bash@" "@sshEnrichKeysYamlScript@" \
			"$sshKeyProfileName" \
			"$hostIdent" \
			"$selected_runtime_yaml" \
			"$generated_keys_yaml" \
			"$hostsCatalogCsv" \
			"$userName"

		"@bash@" "@sshSplitKeysYamlScript@" \
			"$generated_keys_yaml" \
			"$generated_system_yaml" \
			"$generated_profile_yaml" \
			"$userName"

		install -m 0400 "$generated_profile_yaml" "$effectiveSSHKeysYamlPath"
		install -m 0400 "$generated_profile_yaml" "$alternateSystemSplitProfileKeysYamlPath"
		rm -rf "$tmp_split_dir"
	fi

	chown "$userName:$(id -gn "$userName" 2>/dev/null || echo "$userName")" "$effectiveSSHKeysYamlPath" 2>/dev/null || true
}

# shellcheck disable=SC1091
source @bashTrampoline@
# shellcheck disable=SC1091
source @logger@
ndh::logger:command:run "@loggerTag@" main "$@"
