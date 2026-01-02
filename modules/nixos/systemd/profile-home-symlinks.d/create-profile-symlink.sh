set -euo pipefail
target_home="$1"
link_path="$2"
if [ ! -d "$target_home" ]; then
  echo "[profile-home-symlinks] target '$target_home' not present, skip $link_path" >&2
  exit 0
fi
case "$link_path" in
  "$target_home"/*)
    echo "[profile-home-symlinks] skip $link_path (would reside inside target)" >&2
    exit 0 ;;
esac
if [ -e "$link_path" ] && [ ! -L "$link_path" ]; then
  echo "[profile-home-symlinks] $link_path exists (not symlink), skipping" >&2
  exit 0
fi
mkdir -p "$(dirname "$link_path")"
ln -snf "$target_home" "$link_path"
echo "[profile-home-symlinks] $link_path -> $target_home"
