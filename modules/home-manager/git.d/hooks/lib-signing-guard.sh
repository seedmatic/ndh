#!/usr/bin/env bash
# Shared guard: every commit a push would publish is SIGNED by a key the allowed-signers file
# trusts, and authored under an identity that file names.
#
# A commit made without the global git config — `GIT_CONFIG_GLOBAL=/dev/null`, once the way
# sessions kept a sops driver from decrypting — carries no signature and the user@host identity
# git falls back to, and runs no hook: ndh 5cbbdee0 reached GitHub that way. This is the last
# local gate before the server.
#
# Only commits the remote does not already hold are read: those no remote-tracking ref holds
# (`--not --remotes`) AND those not reachable from the remote's current tip for this ref, which the
# pre-push receives on stdin. The second matters for a remote with no tracking ref at all — a
# branch.<b>.pushRemote never fetched — where --remotes alone would judge the whole history. History
# already published — someone else's, a subtree pulled from another remote — is never re-judged. A
# deletion publishes nothing.
#
# For an SSH signature `%G?` is `G` as soon as the key is in gpg.ssh.allowedSignersFile under ANY
# principal — git does not tie it to the committer — so the committer must also match the principal
# the key was found under (`%GS`): the operator's key may not sign as a bot, nor a bot key as the
# operator.

zero_sha="0000000000000000000000000000000000000000"

# The identity patterns the allowed-signers file names (its first column), one per line — ssh
# patterns, so `rke2lab+*@domain` names every bot of that domain.
allowed_principals() {
  local file
  file="$(git config gpg.ssh.allowedSignersFile 2>/dev/null)" || return 0
  [ -r "$file" ] || return 0
  awk '!/^[[:space:]]*(#|$)/ {print $1}' "$file" | tr ',' '\n'
}

# Echo one line per commit of the push that fails the rule: "<sha> <reason>".
# $1 = the local sha being pushed, $2 = the remote's current sha for that ref (zeros for a new ref).
unsigned_commits_in() {
  local local_sha="$1" remote_sha="${2:-$zero_sha}" principals revs sha mark author committer signer
  local -a published=(--remotes)
  [ "$local_sha" = "$zero_sha" ] && return 0
  # The remote's tip counts as published only if we hold it: an unknown object would make rev-list
  # fail, and without it the judgement stays as strict as --remotes alone.
  if [ "$remote_sha" != "$zero_sha" ] && git cat-file -e "${remote_sha}^{commit}" 2>/dev/null; then
    published+=("$remote_sha")
  fi
  revs="$(git rev-list "$local_sha" --not "${published[@]}")"
  # Nothing new: stop here — `git log` given no revision would read HEAD instead.
  [ -n "$revs" ] || return 0
  principals="$(allowed_principals)"
  while IFS='|' read -r sha mark author committer signer; do
    [ -n "$sha" ] || continue
    if [ "$mark" != "G" ]; then
      echo "$sha signature '${mark}' (G = good and trusted is required)"
    elif ! principal_allowed "$committer" "$(tr ',' '\n' <<<"$signer")"; then
      echo "$sha committer <${committer}> does not match the signing key's principal <${signer}>"
    elif ! principal_allowed "$author" "$principals"; then
      echo "$sha author <${author}> is not an allowed signer"
    elif ! principal_allowed "$committer" "$principals"; then
      echo "$sha committer <${committer}> is not an allowed signer"
    fi
  done < <(git log --stdin --no-walk=unsorted --format='%H|%G?|%ae|%ce|%GS' <<<"$revs")
}

# True when $1 matches one of the newline-separated patterns in $2 (ssh's * and ? wildcards).
principal_allowed() {
  local pattern
  while IFS= read -r pattern; do
    [ -n "$pattern" ] || continue
    # shellcheck disable=SC2053 # the pattern is matched as a glob on purpose
    [[ "$1" == $pattern ]] && return 0
  done <<<"$2"
  return 1
}

# $1 = newline-separated "<sha> <reason>" lines, $2 = the ref they were headed for.
reject_unsigned() {
  echo "─────────────────────────────────────────────────────────────" >&2
  echo "  BLOCKED: '${2}' would publish commits that are not signed by a trusted key." >&2
  echo "" >&2
  while IFS= read -r line; do [ -n "$line" ] && echo "    • $line" >&2; done <<<"$1"
  echo "" >&2
  echo "  A commit made without the global git config (GIT_CONFIG_GLOBAL=/dev/null) has no" >&2
  echo "  signature and a user@host identity. Re-sign without changing the tree:" >&2
  echo "    git rebase --exec 'git commit --amend --no-edit --reset-author -S' <base>" >&2
  echo "  A git subtree commit needs -S on the subtree command." >&2
  echo "─────────────────────────────────────────────────────────────" >&2
}
