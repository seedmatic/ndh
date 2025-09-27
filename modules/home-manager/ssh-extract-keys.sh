#!/usr/bin/env -S bash -euxo pipefail

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
    .key as $authorityName | 
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
