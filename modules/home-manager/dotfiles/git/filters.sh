#!/usr/bin/env -S bash -euo pipefail
# -*- mode: sh -*-

sops='$XDG_CONFIG_DIR/git/filters.d/scripts/sops'

declare -a paths

sops::filter() {
  name=sops
  fmt=${1:-}
  [[ $# -eq 1 ]] && name=${name}-${fmt}

  paths+=("filters.d/$name")

  cat <<EOF > filters.d/$name
[filter "$name"]
  clean = $name clean %f $fmt
  smudge = $name clean %f $fmt
EOF
}


sops::filter

for fmt in yaml json xml props csv tsv base64 uri toml lua; do
  sops::filter $fmt
done

# Generate the include file
cat <<EOF > filters
[include]
$(for path in "${paths[@]}"; do
    echo "  path = $path"
  done)
EOF
