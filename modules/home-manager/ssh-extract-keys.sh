#!/usr/bin/env -S bash -euxo pipefail

shopt -s nullglob

yamlFile="$1"
outputDir="$2"

mkdir -p "$outputDir"

exp=$( cat <<'EOE' | cut -c 3-
  . | to_entries[] | 
  .key as $name |
  # Use key name as filename base directly (YAML key names are already hyphenated)
  $name as $fname |
  .value.private as $private | 
  .value.public as $public | 
  .value.usage // [] as $usage |
  [
    {
      "filename": ("$OUTPUT_DIR/" + $fname), 
      "content": $private
    },
    {
      "filename": ( "$OUTPUT_DIR/" + $fname + (
        { "suffix": ".pub" } | with( 
            select ( [ "ssh-authority"] - $usage | length == 0 );
            .suffix = "-ca.pub"
          ) | .suffix
        )
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
    [{"filename": ("$OUTPUT_DIR/" + $fname + "-" + $authorityName + "-ca.pub"), "content": $authorityPublic}]
  ) // []
  | (.. | select(tag == "!!str")) |= envsubst
  | .[] | select(.content != null) | splitdoc
EOE
)

: Use yq to generate the array, split it into files, and output to the specified directory
env OUTPUT_DIR="$outputDir" yq eval "$exp" "$yamlFile" -s '.filename'

: Post-process the generated YAML files to extract only the content
# Only touch files created by yq (*.yml split output); leave agent-keys and other non-YAML files untouched.
for file in "$outputDir/"*.yml; do
  [[ -f "$file" ]] || continue
  newfile="${file%.yml}"
  mv "$file" "$newfile"
  yq eval '.content | trim' -i "$newfile"
done

# Provide stable symlink names (<key>-cert.pub) pointing to a matching user certificate.
# Match is validated by comparing key fingerprint and certificate embedded public-key fingerprint.
for priv in "$outputDir/"*; do
  [[ -f "$priv" ]] || continue
  case "$priv" in
    *.pub) continue ;;
  esac
  base="${priv##*/}"
  certs=("$outputDir/${base}"-*-user-cert.pub)

  key_fp="$(ssh-keygen -lf "$priv" 2>/dev/null | awk '{print $2}' || true)"
  if [[ -z "$key_fp" ]]; then
    rm -f "$outputDir/${base}-cert.pub"
    continue
  fi

  matched_cert=""
  for cert in "${certs[@]}"; do
    [[ -f "$cert" ]] || continue
    cert_fp="$(ssh-keygen -Lf "$cert" 2>/dev/null | awk '/Public key:/ {print $4; exit}' || true)"
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
