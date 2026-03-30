#!/usr/bin/env -S bash -euxo pipefail

shopt -s nullglob

yamlFile="$1"
outputDir="$2"

mkdir -p "$outputDir"

exp=$( cat <<'EOE' | cut -c 3-
  .keys | to_entries[] | 
  .key as $name |
  # Derive a filesystem filename base where underscores are converted back to hyphens
  ($name | sub("_"; "-")) as $fname |
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
    .value.certificates | to_entries[] | 
    .key as $authorityNameRaw | 
    ($authorityNameRaw | sub("_"; "-")) as $authorityName |
    .value | to_entries[] | select(.key | test("^ssh-")) |
      .value as $certContent |
      .key | sub("^ssh-(.*)$", "${1}") as $certType |
      ( 
        "-" + $authorityName + "-" + $certType + "-cert.pub"
      ) as $certSuffix |
    [{"filename": ("$OUTPUT_DIR/" + $fname +  $certSuffix), "content": $certContent}]
  ) // []
  | (.. | select(tag == "!!str")) |= envsubst
  | .[] | select(.content != null) | splitdoc
EOE
)

: Use yq to generate the array, split it into files, and output to the specified directory
env OUTPUT_DIR="$outputDir" yq eval "$exp" "$yamlFile" -s '.filename'

: Post-process the generated YAML files to extract only the content
for file in "$outputDir/"*; do
  if [[ $file == *.yml ]]; then
    file=${file%.yml}
    mv "${file}".yml "${file}"
  fi
  yq eval '.content | trim' -i "$file"
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
