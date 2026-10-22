#!/usr/bin/env bash
# SessionStart hook: in a repository that holds a flake, a file resolving to a sops filter means a checkout
# here may have left secrets in the CLEAR on disk, a stale checkout included. Say it before the session
# reads anything, and name the files to leave unread. The logic is the global git hooks' own
# (lib-sops-filter-guard.sh, copied beside this script): one source for the commit and the session.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../git.d/hooks/lib-sops-filter-guard.sh
. "${here}/lib-sops-filter-guard.sh"

cwd="$(yq -p=json -o=json -r '.cwd // ""' 2>/dev/null || true)"
[[ -n "$cwd" && -d "$cwd" ]] || exit 0
top="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)" || exit 0
cd "$top"
repo_holds_flake || exit 0

hits="$(sops_filtered_paths_any)"
[[ -n "$hits" ]] || exit 0

list=""
while read -r path _; do
  if is_decrypted_on_disk "$path"; then list+="${path} (IN THE CLEAR ON DISK), "; else list+="${path}, "; fi
done <<<"$(head -20 <<<"$hits")"

TOP="$top" L="${list%, }" yq -n -o=json -I0 '{"systemMessage": ("⛔ sops-filter-guard: " + strenv(TOP) + " holds a flake, yet these files resolve to a sops filter, so a checkout may have decrypted them on disk. Do NOT read them; tell the operator: " + strenv(L))}'
