# keys-reconcile close <rev12> (design §p's discipline): discard ONE window left open, unmerged — its worktree and its
# branch in the fetch cache. Sourced by keys-reconcile.sh; armed (F3). The only gesture that removes a window: a
# window holds a key commit, which only the operator's armed gesture writes, so only theirs removes it.
#
# Refused, nothing removed, unless: the argument is a revision's 12-character prefix (never a path); that window exists
# under the state directory; its worktree is on the branch keys-reconcile/<rev12> of the fetch cache, with nothing
# uncommitted; and its commit is on neither develop nor main of the cache (a merged window is gone already).

reconcile::close() { # <rev12>
  local rev12="$1" state tree branch head
  [[ $rev12 =~ ^[0-9a-f]{12}$ ]] || die "close: '${rev12}' is not a revision's 12-character prefix"
  state="${XDG_STATE_HOME:-$HOME/.local/state}/keys-reconcile"
  tree="${state}/${rev12}"
  branch="keys-reconcile/${rev12}"
  [[ -d $tree && ! -L $tree ]] || die "close: no window ${tree}"
  [[ "$(git -C "$tree" rev-parse --git-common-dir 2>/dev/null)" == "$bare" ]] ||
    die "close: ${tree} is not a worktree of ${bare}"
  [[ "$(git -C "$tree" rev-parse --abbrev-ref HEAD 2>/dev/null)" == "$branch" ]] ||
    die "close: ${tree} is not on ${branch}"
  [[ -z "$(git -C "$tree" status --porcelain 2>/dev/null)" ]] || die "close: ${tree} has uncommitted changes"
  head=$(git -C "$tree" rev-parse HEAD)
  local ref
  for ref in develop main; do
    ! git -C "$bare" merge-base --is-ancestor "$head" "refs/heads/$ref" 2>/dev/null ||
      die "close: ${branch} (${head:0:12}) is already on ${ref}: nothing to discard"
  done

  echo "close window ${rev12} without merging it: ${branch}, $(git -C "$tree" log -1 --format='%h %s')"
  local answer
  printf 'delete this window and its branch? [yes/no] ' >>"$ttyOut"
  exec 7<"$ttyIn"
  read -r answer <&7 || answer=""
  exec 7<&-
  [[ $answer == yes ]] || { echo "nothing deleted: the answer is not « yes »"; return 5; }
  git -C "$bare" worktree remove "$tree" || die "close: the worktree ${tree} could not be removed"
  git -C "$bare" branch -D "$branch" >/dev/null || die "close: the branch ${branch} could not be deleted"
  [[ ! -e $tree ]] || die "close: ${tree} is still there"
  ! git -C "$bare" rev-parse --verify -q "refs/heads/${branch}" >/dev/null || die "close: ${branch} is still there"
  echo "closed: ${branch} deleted, nothing was merged."
}
