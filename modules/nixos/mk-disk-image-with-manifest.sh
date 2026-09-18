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

  if [[ -z "${NDH_PREBUILT_IMAGES_SPEC_YAML_FILE:-}" || ! -f "${NDH_PREBUILT_IMAGES_SPEC_YAML_FILE:-}" ]]; then
    echo "[flake][ERROR] NDH_PREBUILT_IMAGES_SPEC_YAML_FILE must reference an existing file" >&2
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

  # `install -m` and not `cp`: the base manifest is a store path (mode 0444), and
  # cp would carry that mode over, leaving every `yq -i` below unable to write.
  # yq reports such a failure but still exits 0, so `set -e` does not catch it —
  # the images list would silently stay empty (which it did, until this fix).
  install -m 0644 "$NDH_MANIFEST_BASE_YAML_FILE" "$out_dir/manifest.yaml"

  while IFS=$'\t' read -r image_name image_size_mib; do
    [[ -z "$image_name" ]] && continue
    if [[ ! -e "$out_dir/$image_name" ]]; then
      truncate -s "${image_size_mib}M" "$out_dir/$image_name"
    fi
  done < <(yq -r '.[] | [.name + ".img", (.sizeMiB | tostring)] | @tsv' "$NDH_EXTRA_IMAGES_SPEC_YAML_FILE")

  # Prebuilt images are whole filesystem images produced by their own
  # derivation (e.g. the read-only EROFS store lower).  Unlike extraImages
  # these are never blank-created or resized — symlink them so the bundle
  # costs nothing and each stays independently substitutable.
  declare -A prebuilt_images=()

  while IFS=$'\t' read -r image_name image_path; do
    [[ -z "$image_name" ]] && continue
    if [[ -e "$out_dir/$image_name" ]]; then
      echo "[flake][ERROR] prebuilt image collides with an existing image: $image_name" >&2
      exit 1
    fi
    if [[ ! -f "$image_path" ]]; then
      echo "[flake][ERROR] prebuilt image missing: $image_path" >&2
      exit 1
    fi
    ln -s "$image_path" "$out_dir/$image_name"
    prebuilt_images["$image_name"]=1
  done < <(yq -r '.[] | [.name + ".img", .path] | @tsv' "$NDH_PREBUILT_IMAGES_SPEC_YAML_FILE")

  while IFS= read -r candidate; do
    image_name="$(basename "$candidate")"
    image_label="${image_name%.img}"

    export IMAGE_NAME="$image_name"
    export IMAGE_LABEL="$image_label"
    if [[ "$image_name" == "$NDH_PRIMARY_IMAGE_PATH" ]]; then
      yq -i '.images += [{"name": strenv(IMAGE_LABEL), "path": strenv(IMAGE_NAME), "role": "primary"}]' "$out_dir/manifest.yaml"
    elif [[ -n "${prebuilt_images["$image_name"]+x}" ]]; then
      # Role carries a real contract to the Darwin side: a prebuilt image is a
      # finished read-only filesystem, so it is materialized verbatim and must
      # never be grown to vmDataDiskSizeGiB or probed for ZFS partition labels
      # the way a pool member disk is.
      yq -i '.images += [{"name": strenv(IMAGE_LABEL), "path": strenv(IMAGE_NAME), "role": "prebuilt"}]' "$out_dir/manifest.yaml"
    else
      yq -i '.images += [{"name": strenv(IMAGE_LABEL), "path": strenv(IMAGE_NAME)}]' "$out_dir/manifest.yaml"
    fi
  done < <(find "$out_dir" -maxdepth 1 \( -type f -o -type l \) -name '*.img' | LC_ALL=C sort)

  if [[ -f "$out_dir/boot-size-hint.yaml" ]]; then
    export HINT_FILE="$out_dir/boot-size-hint.yaml"
    # Guard reads the hint file itself: `yq -e … /dev/null` evaluates against an
    # empty document and always failed with "no matches found".  The payload is
    # `zpool status --json`, i.e. a map ({output_version, pools}) — the previous
    # `type == "!!seq"` test could never have matched either.
    if yq -e '.zpools != null' "$HINT_FILE" >/dev/null 2>&1; then
      yq -i '.zpools = load(strenv(HINT_FILE)).zpools' "$out_dir/manifest.yaml"
    fi
  fi
}

ndh::logger:command:run "@loggerTag@" main "$@"
