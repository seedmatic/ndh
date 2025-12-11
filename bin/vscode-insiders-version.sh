#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
repo_dir=$(cd "${script_dir}/.." && pwd -P)
nvfetcher_file="${repo_dir}/nvfetcher.toml"
print_only=0
declare -a platforms=()

usage() {
  cat <<'EOF'
Update nvfetcher metadata for VS Code Insiders artifacts.

USAGE:
  vscode-insiders-version.sh [options] [platform...]

OPTIONS:
  -p, --print      Only print metadata, do not touch nvfetcher.toml
  -f, --file PATH  Path to nvfetcher.toml (default: repo root)
  -h, --help       Show this message

PLATFORMS:
  linux-arm64, darwin-arm64. Defaults to both when omitted.
EOF
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing dependency: $1" >&2
    exit 2
  fi
}

require_cmd curl
require_cmd yq
require_cmd dasel

dasel_delete() {
  dasel delete -f "$nvfetcher_file" -r toml -w toml "$1" >/dev/null 2>&1 || true
}

dasel_put() {
  local selector="$1"
  local value="$2"
  dasel put -f "$nvfetcher_file" -r toml -w toml -t string -v "$value" "$selector"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--print)
      print_only=1
      shift
      ;;
    -f|--file)
      [[ $# -ge 2 ]] || { echo "--file requires a path" >&2; exit 2; }
      nvfetcher_file="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    linux-*|darwin-*)
      platforms+=("$1")
      shift
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ ${#platforms[@]} -eq 0 ]]; then
  platforms=("linux-arm64" "darwin-arm64")
fi

fetch_payload() {
  local platform="$1"
  local api_url="https://update.code.visualstudio.com/api/update/${platform}/insider/latest"
  curl -fsSL "$api_url"
}

extract_field() {
  local payload="$1"
  local query="$2"
  printf '%s' "$payload" | yq -p json -o tsv "$query"
}

update_platform() {
  local platform="$1"
  local payload version url product sha
  payload=$(fetch_payload "$platform")
  version=$(extract_field "$payload" '.version // ""')
  url=$(extract_field "$payload" '.url // ""')
  product=$(extract_field "$payload" '.productVersion // ""')
  sha=$(extract_field "$payload" '.sha256hash // ""')

  if [[ -z "$version" || -z "$url" ]]; then
    echo "failed to read metadata for ${platform}" >&2
    exit 3
  fi

  local filename="${url##*/}"
  if [[ $print_only -eq 1 ]]; then
    printf '%-15s %s (%s)\n' "$platform" "$product" "$version"
    printf '  url: %s\n' "$url"
    printf '  sha256: %s\n' "$sha"
    return
  fi

  local section="vscode-insiders-${platform}"
  local section_selector="${section}"

  # Remove src.cmd to avoid conflicts once manual pinning is in place.
  dasel_delete "${section_selector}.src.cmd"
  dasel_put "${section_selector}.src.manual" "$version"
  dasel_put "${section_selector}.fetch.url" "$url"
  dasel_put "${section_selector}.fetch.name" "$filename"

  echo "updated ${section} -> ${version} (${filename})"
}

for platform in "${platforms[@]}"; do
  update_platform "$platform"
done

if [[ $print_only -eq 0 ]]; then
  echo "done. run nvfetcher to refresh hashes."
fi
