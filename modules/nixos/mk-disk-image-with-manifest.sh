#!/usr/bin/env bash
# shellcheck source=/dev/null
source "@nixBashTrampoline@"

main() {
  set -euo pipefail
  set -x

  out_dir="$1"
  source_dir="$2"

  if [[ ! -d "$source_dir" ]]; then
    echo "[flake][ERROR] source must be a directory: $source_dir" >&2
    exit 1
  fi

  if [[ -z "${NDH_PRIMARY_IMAGE_PATH:-}" ]]; then
    echo "[flake][ERROR] NDH_PRIMARY_IMAGE_PATH is required" >&2
    exit 1
  fi

  if [[ -z "${NDH_MANIFEST_BASE_YAML_FILE:-}" || ! -f "${NDH_MANIFEST_BASE_YAML_FILE:-}" ]]; then
    echo "[flake][ERROR] NDH_MANIFEST_BASE_YAML_FILE must reference an existing file" >&2
    exit 1
  fi

  if [[ -z "${NDH_EXTRA_IMAGES_SPEC_YAML_FILE:-}" || ! -f "${NDH_EXTRA_IMAGES_SPEC_YAML_FILE:-}" ]]; then
    echo "[flake][ERROR] NDH_EXTRA_IMAGES_SPEC_YAML_FILE must reference an existing file" >&2
    exit 1
  fi

  if [[ ! -f "$source_dir/$NDH_PRIMARY_IMAGE_PATH" ]]; then
    echo "[flake][ERROR] primary image missing from source directory: $source_dir/$NDH_PRIMARY_IMAGE_PATH" >&2
    exit 1
  fi

  mkdir -p "$out_dir"

  declare -a source_images=()
  declare -A image_seen=()

  add_source_image() {
    local candidate="$1"
    if [[ -n "$candidate" && -f "$candidate" && -z "${image_seen["$candidate"]+x}" ]]; then
      source_images+=("$candidate")
      image_seen["$candidate"]=1
    fi
  }

  while IFS= read -r candidate; do
    add_source_image "$candidate"
  done < <(find "$source_dir" -maxdepth 1 -type f -name '*.img' | LC_ALL=C sort)

  if [[ ${#source_images[@]} -eq 0 ]]; then
    echo "[flake][ERROR] no *.img files found in source directory: $source_dir" >&2
    exit 1
  fi

  for candidate in "${source_images[@]}"; do
    image_name="$(basename "$candidate")"
    ln -s "$candidate" "$out_dir/$image_name"
  done

  if [[ -f "$source_dir/boot-size-hint.yaml" ]]; then
    ln -s "$source_dir/boot-size-hint.yaml" "$out_dir/boot-size-hint.yaml"
  fi

  cp "$NDH_MANIFEST_BASE_YAML_FILE" "$out_dir/manifest.yaml"

  while IFS=$'\t' read -r image_name image_size_mib; do
    [[ -z "$image_name" ]] && continue
    if [[ ! -e "$out_dir/$image_name" ]]; then
      truncate -s "${image_size_mib}M" "$out_dir/$image_name"
    fi
  done < <(yq -r '.[] | [.name + ".img", (.sizeMiB | tostring)] | @tsv' "$NDH_EXTRA_IMAGES_SPEC_YAML_FILE")

  while IFS= read -r candidate; do
    image_name="$(basename "$candidate")"
    image_label="${image_name%.img}"

    export IMAGE_NAME="$image_name"
    export IMAGE_LABEL="$image_label"
    if [[ "$image_name" == "$NDH_PRIMARY_IMAGE_PATH" ]]; then
      yq -i '.images += [{"name": strenv(IMAGE_LABEL), "path": strenv(IMAGE_NAME), "role": "primary"}]' "$out_dir/manifest.yaml"
    else
      yq -i '.images += [{"name": strenv(IMAGE_LABEL), "path": strenv(IMAGE_NAME)}]' "$out_dir/manifest.yaml"
    fi
  done < <(find "$out_dir" -maxdepth 1 \( -type f -o -type l \) -name '*.img' | LC_ALL=C sort)

  if [[ -f "$out_dir/boot-size-hint.yaml" ]]; then
    export HINT_FILE="$out_dir/boot-size-hint.yaml"
    if yq -e 'load(strenv(HINT_FILE)).zpools != null and (load(strenv(HINT_FILE)).zpools | type == "!!seq")' /dev/null >/dev/null; then
      yq -i '.zpools = (load(strenv(HINT_FILE)).zpools // [])' "$out_dir/manifest.yaml"
    fi
  fi
}

ndh::logger:command:run "@loggerTag@" main "$@"
