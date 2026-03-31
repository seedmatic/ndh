#!/usr/bin/env -S bash -euxo pipefail

shopt -s nullglob

main() {
	yamlFile="$1"
	outputDir="$2"

	mkdir -p "$outputDir"

	exp=$(
		cat <<'EOE' | cut -c 3-
  .keys | to_entries[] | 
  env(TMPDIR) + "/" as $tmpdir |
  ( .key | sub("_", "-") ) as $basename |
  ( $basename + ".yaml" ) as $yamlfile |
  ( $tmpdir + $yamlfile ) as $yamlfile |
  .value.private as $private | 
  .value.public as $public | 
  .value.usage // [] as $usage |
  [
    {
      "yamlfile": $yamlfile, 
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
        "content": $authorityCerts."ssh-host"
      },
      {
        "yamlfile": ( $tmpdir + $basename + "-" + $authorityName + "-user-cert.pub.yaml"),
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
	# Only touch files created by yq (*.yml split output); leave agent-keys and other non-YAML files untouched.
	for yamlFile in "$tmpDir"/*; do
		filename="${yamlFile##*/}"
		filename="${filename%.yaml}"
		contentFile="$outputDir/$filename"
		mv "$yamlFile" "$contentFile"
		@yq@ --inplace eval '.content | trim' "$contentFile"
	done
	rm -fr "tmpDir"

	: "Provide stable symlink names (<key>-cert.pub) pointing to a matching user certificate."
	# Match is validated by comparing key fingerprint and certificate embedded public-key fingerprint.
	for priv in "$outputDir/"*; do
		[[ -f "$priv" ]] || continue
		case "$priv" in
		*.pub) continue ;;
		esac
		base="${priv##*/}"
		certs=("$outputDir/${base}"-*-user-cert.pub)

		key_fp="$(@ssh-keygen@ -lf "$priv" 2>/dev/null | @awk@ '{print $2}' || true)"
		if [[ -z "$key_fp" ]]; then
			rm -f "$outputDir/${base}-cert.pub"
			continue
		fi

		matched_cert=""
		for cert in "${certs[@]}"; do
			[[ -f "$cert" ]] || continue
			cert_fp="$(@ssh-keygen@ -Lf "$cert" 2>/dev/null | @awk@ '/Public key:/ {print $4; exit}' || true)"
			if [[ -n "$cert_fp" && "$cert_fp" == "$key_fp" ]]; then
				matched_cert="$cert"
				break
			fi
		done

		if [[ -n "$matched_cert" ]]; then
			cert_basename="${matched_cert##*/}"
			ln -sf "$cert_basename" "$outputDir/${base}-cert.pub"
		else
			rm -f "$outputDir/${base}-cert.pub"
		fi
	done
}

source @activationLogger@
activation_run "@activationTag@" main "$@"
