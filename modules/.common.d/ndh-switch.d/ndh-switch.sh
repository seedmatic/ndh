# ndh-switch: switch ONE machine to a pushed, merged revision of ndh. The sessions' only switch verb: the raw
# darwin-rebuild / nixos-rebuild / home-manager switch stay denied to them by the managed list.
#
# The flake is always github:seedmatic/ndh/<sha>, so a working tree, a dirty tree or an unpushed commit cannot be
# switched to: GitHub cannot serve them. The revision must also be merged into develop or main (we switch from
# develop to validate). Machines and their order come from machines.json, which the fleet loop reads too.
# The ancestry is read from the canonical remote, fixed at build time: a fork would pass the check, and GitHub serves
# a fork network's commits under github:seedmatic/ndh/<sha>.
# Run from darwin.bioskop: the guests are evaluated there and pushed (keys.yaml's IFD is aarch64-darwin).
set -euo pipefail

state="${XDG_STATE_HOME:-$HOME/.local/state}/ndh-switch"
cache="${XDG_CACHE_HOME:-$HOME/.cache}/ndh-switch/ndh.git"
machine="" rev="" dry=0

log() { # $1 = outcome
  mkdir -p "$state"
  printf '%s %s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${machine:--}" "${rev:--}" "$1" >>"$state/log"
  logger -t ndh-switch "${machine:--} ${rev:--} $1" 2>/dev/null || true
}

refuse() {
  echo "ndh-switch: refused: $*" >&2
  log "refused: $*"
  exit 3
}

usage() {
  echo "usage: ndh-switch [--dry-run] <machine> <rev>   (machines: $(jq -r 'map(.name) | join(" ")' "$machines"))" >&2
  exit 2
}

[[ ${1:-} == --dry-run ]] && dry=1 && shift
(($# == 2)) || usage
machine=$1 rev=$2

host=$(uname -n)
host=${host%%.*}
[[ $host == "$seat" ]] || refuse "runs from darwin.$seat only, not $host"
[[ $rev =~ ^[0-9a-f]{40}$ ]] || refuse "not a full revision: $rev"
entry=$(jq -ce --arg m "$machine" '.[] | select(.name == $m)' "$machines") || refuse "unknown machine: $machine"

[[ -d $cache ]] || git init -q --bare "$cache"
git -C "$cache" fetch -q --filter=blob:none "$remote" +refs/heads/develop:refs/heads/develop +refs/heads/main:refs/heads/main ||
  refuse "cannot fetch develop and main from $remote"
on=""
for branch in develop main; do
  if git -C "$cache" merge-base --is-ancestor "$rev" "refs/heads/$branch" 2>/dev/null; then
    on=$branch
    break
  fi
done
[[ -n $on ]] || refuse "$rev is not merged into develop or main of $remote"

flake="github:seedmatic/ndh/$rev"
kind=$(jq -r .kind <<<"$entry")
ssh_name=$(jq -r .ssh <<<"$entry")
mapfile -t ssh_opts < <(jq -r '.ssh_opts[]' <<<"$entry")

case $kind in
  nixos) cmd=(nixos-rebuild switch --flake "$flake#$machine" --target-host "root@$ssh_name") ;;
  darwin)
    # macOS's own setuid sudo, and nix-darwin does not restart the daemon when only nix.conf changes.
    remote_cmd="/usr/bin/sudo /run/current-system/sw/bin/darwin-rebuild switch --flake '$flake#$machine' && /usr/bin/sudo launchctl kickstart -k system/org.nixos.nix-daemon"
    if [[ -z $ssh_name ]]; then
      cmd=(bash -c "$remote_cmd")
    else
      cmd=(ssh "${ssh_opts[@]}" "$ssh_name" "$remote_cmd")
    fi
    ;;
  *) refuse "unknown kind for $machine: $kind" ;;
esac

echo "ndh-switch: $machine -> $flake (on $on)"
echo "+ ${cmd[*]}"
if ((dry)); then
  log "dry-run ($on)"
  exit 0
fi
log "started ($on)"
if "${cmd[@]}"; then
  log "switched ($on)"
else
  status=$?
  log "failed: exit $status"
  exit "$status"
fi
