#!/usr/bin/env -S bash -euo pipefail
# @codebase
# ★ xtrace-guard — no trace, whatever the invocation (bash -x, an inherited SHELLOPTS=xtrace, a
# caller's set -x): this script handles a private key, and a trace prints every value it expands.
case $- in *x*) { set +x; } 2>/dev/null; echo "[xtrace-guard] xtrace disabled: this script handles private keys" >&2 ;; esac
export -n SHELLOPTS 2>/dev/null || true # readonly in bash, so not unset; un-exported, it stops at this process
unset NDH_LOGGER_XTRACE # ndh::logger:command:run traces its command only when this is 1
unset BASH_XTRACEFD 2>/dev/null || true
source @nixBashTrampoline@

# ndh-host-key-generate: give this machine its next host key, born here (roles × keys K3, the fabric-delivery frame).
# Rendered by pkgs.replaceVars: machine, slot, keyFile, publishDir, oldKey and oldPublic, all fixed at evaluation
# from keys.yaml's ONE pending host-<machine> slot; a machine with no pending slot does not run this at all.
#
# Idempotent at every activation: the private is generated once, by a rename into place, so it is absent or whole,
# never regenerated while present. The publication — the public and the F1 statement binding it to the machine's
# OLD certified key (namespace seedmatic-rotate) — is re-derived from that private every time, so a run that
# stopped between the two is completed by the next. Nothing serves the new key: sshd and sops keep the old one
# until keys.yaml records the slot and a later switch serves it. Only publics are printed.

readonly machine=@machine@ slot=@slot@ keyFile=@keyFile@ publishDir=@publishDir@ oldKey=@oldKey@ oldPublic=@oldPublic@

die() {
  printf '[ndh-host-key-generate] ERROR: %s\n' "$*" >&2
  exit 1
}

main() {
  umask 077
  keyDir="$(dirname "$keyFile")"
  install -d -m 0700 "$keyDir"

  if [[ ! -e $keyFile ]]; then
    tmp="$(mktemp -d "${keyDir}/.generate.XXXXXX")"
    trap 'rm -rf "$tmp"' EXIT
    ssh-keygen -q -t ed25519 -N "" -C "host-${machine}@${slot}" -f "$tmp/key" </dev/null || die "ssh-keygen failed"
    chmod 0600 "$tmp/key"
    mv -f "$tmp/key" "$keyFile"
    rm -rf "$tmp"
    trap - EXIT
    printf '[ndh-host-key-generate] host-%s@%s generated at %s\n' "$machine" "$slot" "$keyFile" >&2
  fi
  [[ -f $keyFile && ! -L $keyFile ]] || die "${keyFile} is not a regular file"

  public="$(ssh-keygen -y -f "$keyFile" | cut -d' ' -f1,2)" || die "${keyFile} is not a readable ed25519 private"
  [[ $public == ssh-ed25519\ * ]] || die "${keyFile} is not an ed25519 key"

  # F1: the OLD certified key vouches for the new public. Its public must be the one keys.yaml records, so a
  # replaced old key signs nothing.
  [[ -s $oldKey ]] || die "no old host key at ${oldKey} to sign the new public with"
  [[ "$(ssh-keygen -y -f "$oldKey" | cut -d' ' -f1,2)" == "$oldPublic" ]] ||
    die "${oldKey} is not the host key keys.yaml records for ${machine}: nothing published"

  install -d -m 0755 "$publishDir"
  work="$(mktemp -d "${publishDir}/.publish.XXXXXX")"
  trap 'rm -rf "$work"' EXIT
  printf 'seedmatic-rotate v1\nname host-%s\nslot %s\nkey %s\n' "$machine" "$slot" "$public" >"$work/statement"
  ssh-keygen -q -Y sign -f "$oldKey" -n seedmatic-rotate "$work/statement" </dev/null || die "signing the statement failed"
  printf '%s\n' "$public" >"$work/public"
  chmod 0644 "$work/public" "$work/statement" "$work/statement.sig"
  for f in public statement statement.sig; do mv -f "$work/$f" "${publishDir}/host-${machine}@${slot}.${f}"; done
  rm -rf "$work"
  trap - EXIT
  printf '[ndh-host-key-generate] host-%s@%s published: %s\n' "$machine" "$slot" "$(ssh-keygen -lf "${publishDir}/host-${machine}@${slot}.public" | cut -d' ' -f2)" >&2
}

ndh::logger:command:run host-key.generate main "$@"
