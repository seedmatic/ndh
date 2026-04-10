#!/usr/bin/env -S bash -euxo pipefail

shopt -s nullglob

main() {
	yamlFile="$1"
  userOutputDir="$2"
  systemOutputDir="$3"

  mkdir -p "$userOutputDir" "$systemOutputDir"

	exp=$(
		cat <<'EOE' | cut -c 3-
  .keys | to_entries[] | 
  env(TMPDIR) + "/" as $tmpdir |
  ( .value.annotations.file_name // ( .key | gsub("_", "-") ) ) as $basename |
  ( .value.descriptor.extract_folder //
    ( .value.annotations.public_scope // (
      if (([ "ssh-authority"] - (.value.usage // []) | length) == 0) then "system" else "user" end
    )
  ) ) as $public_target |
  ( if ($public_target == "ssh-system-keys" or $public_target == "system") then "system" else "user" end ) as $public_scope |
  ( $basename + ".yaml" ) as $yamlfile |
  ( $tmpdir + $yamlfile ) as $yamlfile |
  .value.private as $private | 
  .value.public as $public | 
  .value.usage // [] as $usage |
  [
    {
      "yamlfile": $yamlfile, 
      "target_dir": "user",
      "content": $private
    },
    {
      "yamlfile": ( $tmpdir + $basename + (
        { "suffix": ".pub" } | with( 
            select ( [ "ssh-authority"] - $usage | length == 0 );
            .suffix = "-ca.pub"
          ) | .suffix
        ) + ".yaml"
      ),
      "target_dir": $public_scope,
      "content": $public
    }
  ] +
  (
    # Current schema: per-key authorities are nested under .authorities.
    # Emit CA public keys with a deterministic suffix for known-hosts/signing helpers.
    (.value.authorities // {}) | to_entries[] |
    .key as $authorityNameRaw |
    $authorityNameRaw as $authorityName |
    .value.public as $authorityPublic |
    select($authorityPublic != null and $authorityPublic != "") |
    [ 
      { 
        "yamlfile": ( $tmpdir + $basename + "-" + $authorityName + "-ca.pub.yaml" ), 
        "target_dir": "system",
        "content": $authorityPublic
      } ]
  ) +
  (
    # Signed certificates are nested under .certificates.<authority>.
    # Emit direct host/user certificate files for consumers that reference them by name.
    (.value.certificates // {}) | to_entries[] |
    .key as $authorityName |
    .value as $authorityCerts |
    [
      {
        "yamlfile": ( $tmpdir + $basename + "-" + $authorityName + "-host-cert.pub.yaml"),
        "target_dir": "system",
        "content": $authorityCerts."ssh-host"
      },
      {
        "yamlfile": ( $tmpdir + $basename + "-" + $authorityName + "-user-cert.pub.yaml"),
        "target_dir": "system",
        "content": $authorityCerts."ssh-user"
      }
    ]
  ) // []
  | .[] 
  | select(.content != null)
  | split_doc
EOE
	)

	: "Use yq to generate the array, split it into files, and output to the specified directory"
	tmpDir="$( mktemp --directory )"
	trap "rm -fr $tmpDir" EXIT &&
		env TMPDIR="$tmpDir" @yq@ eval "$exp" "$yamlFile" -s '.yamlfile'

	: "Post-process to extract only the content"
  # Only touch files created by yq (*.yml split output); leave other non-YAML files untouched.
	for yamlFile in "$tmpDir"/*; do
		filename="${yamlFile##*/}"
		filename="${filename%.yaml}"
    targetDir="$(@yq@ eval -r '.target_dir // "user"' "$yamlFile")"
    if [[ "$targetDir" == "system" ]]; then
      contentFile="$systemOutputDir/$filename"
    else
      contentFile="$userOutputDir/$filename"
    fi
    mv "$yamlFile" "$contentFile"
		contentTmp="$(mktemp)"
		@yq@ eval -r '.content' "$contentFile" > "$contentTmp"
		mv "$contentTmp" "$contentFile"
    if [[ "$filename" == *.pub ]]; then
      chmod 644 "$contentFile"
      if [[ "$filename" == *-cert.pub ]]; then
        @ssh-keygen@ -Lf "$contentFile" >/dev/null
      else
        @ssh-keygen@ -lf "$contentFile" >/dev/null
      fi
    else
      chmod 600 "$contentFile"
    fi

    # Keep canonical public key next to its private key while preserving
    # backward compatibility for consumers reading from systemOutputDir.
    if [[ "$filename" == *.pub && "$filename" != *-cert.pub && "$filename" != *-ca.pub ]]; then
      ln -sf "$contentFile" "$systemOutputDir/$filename"
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
    user_certs=("$systemOutputDir/${base}"-*-user-cert.pub)
    host_certs=("$systemOutputDir/${base}"-*-host-cert.pub)

		key_fp="$(@ssh-keygen@ -lf "$priv" 2>/dev/null | @awk@ '{print $2}' || true)"
		if [[ -z "$key_fp" ]]; then
      rm -f "$userOutputDir/${base}-cert.pub"
      rm -f "$systemOutputDir/${base}-server-cert.pub"
			continue
		fi

    matched_user_cert=""
    for cert in "${user_certs[@]}"; do
			[[ -f "$cert" ]] || continue
			cert_fp="$(@ssh-keygen@ -Lf "$cert" 2>/dev/null | @awk@ '/Public key:/ {print $4; exit}' || true)"
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
      cert_fp="$(@ssh-keygen@ -Lf "$cert" 2>/dev/null | @awk@ '/Public key:/ {print $4; exit}' || true)"
      cert_type="$(@ssh-keygen@ -Lf "$cert" 2>/dev/null | @awk@ '/Type:/ {print $2; exit}' || true)"
      if [[ "$cert_type" == "host" && -n "$cert_fp" && "$cert_fp" == "$key_fp" ]]; then
        matched_host_cert="$cert"
        break
      fi
    done

    if [[ -n "$matched_host_cert" ]]; then
      ln -sf "$matched_host_cert" "$systemOutputDir/${base}-server-cert.pub"
    else
      rm -f "$systemOutputDir/${base}-server-cert.pub"
    fi
	done
}

# shellcheck disable=SC1091
source @bashTrampoline@
# shellcheck disable=SC1091
source @logger@
ndh::logger:command:run "@activationTag@" main "$@"
