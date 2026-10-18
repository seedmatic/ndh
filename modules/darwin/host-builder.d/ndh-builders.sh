# ndh-builders [metalspace | fabric] — which builders this Mac's nix sends its builds to (docs/host-builder-phases.adoc).
# The header sets dir (where the pointer lives), machines (the prefix of the generated lists: <machines>.<mode>)
# and modes (the lists this host has).
#
#   ndh-builders              prints the active mode; fails if there is none, or it points at nothing
#   ndh-builders metalspace   this metalspace's builders only: the guest (the default)
#   ndh-builders fabric       the other metalspace's Mac and guest too, to spread builds when both are close by
#
# nix reads `builders = @<dir>/active` when a command's build hook starts: a new mode applies from the NEXT nix
# command, with no daemon restart. A missing list is skipped SILENTLY by nix, which then builds nothing remotely, so a
# mode whose list is missing or empty is refused here.

active="$dir/active"
usage="usage: ndh-builders [${modes// / | }]"

die() {
  printf '[ndh-builders] ERROR: %s\n' "$*" >&2
  exit 1
}

if (($# == 0)); then
  target="$(readlink "$active" 2>/dev/null)" || die "no active builders set at ${active}: sudo ndh-builders metalspace"
  [[ -s $target ]] || die "${active} points at ${target}, which is missing or empty: sudo ndh-builders metalspace"
  printf '%s\n' "${target##*.}"
  exit 0
fi

(($# == 1)) || die "$usage"
mode="$1"
[[ " ${modes} " == *" ${mode} "* ]] || die "$usage"
target="${machines}.${mode}"
[[ -s $target ]] || die "${target} is missing or empty: nix would skip it silently and every build would fail"

# A rename, so a nix command starting meanwhile reads the old list or the new one, never none.
mkdir -p "$dir" 2>/dev/null || die "cannot create ${dir}: root only (sudo ndh-builders ${mode})"
rm -f "${active}.new" 2>/dev/null || die "cannot write in ${dir}: root only (sudo ndh-builders ${mode})"
{ ln -s "$target" "${active}.new" && mv -fT "${active}.new" "$active"; } 2>/dev/null ||
  die "cannot repoint ${active}: root only (sudo ndh-builders ${mode})"
printf '[ndh-builders] %s, from the next nix command\n' "$mode"
