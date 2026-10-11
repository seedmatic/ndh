# ★ xtrace-guard — no trace, whatever the invocation (bash -x, an inherited SHELLOPTS=xtrace, a
# caller's set -x): this script handles private keys, and a trace prints every value it expands.
case $- in *x*) { set +x; } 2>/dev/null; echo "[xtrace-guard] xtrace disabled: this script handles private keys" >&2 ;; esac
export -n SHELLOPTS 2>/dev/null || true # readonly in bash, so not unset; un-exported, it stops at this process
unset BASH_XTRACEFD 2>/dev/null || true

# incus-cluster-cert-renew — re-mint the Incus CLUSTER certificate under the authority's
# CURRENT signing slot, install it on every member, re-pin the seat's client, verify.
#
# Built BY REVISION and run by the operator from the seat (the hotfix rule): the SAN set,
# the members, the names to verify and the ENCRYPTED keys.yaml are fixed at evaluation —
# nothing evaluates a working tree at run time.
#
# ★ The leaf KEY never touches the repo. It is minted into a 0700 temp dir wiped on exit,
# streamed to ONE member into a 0700 dir on its tmpfs (/run/user/<uid>), installed there through
# the member's LOCAL unix socket (`sudo incus cluster update-certificate`, so no TLS trust is
# widened for the gesture), and deleted. The authority's private is never written: sops is
# piped and step-cli reads the CA through process substitution.
#
# ★ ONE certificate serves every member: `update-certificate` installs it cluster-wide. A
# member still serving the old leaf after the update is restarted (`systemctl restart incus`) —
# safe only while the members run no instance, which the operator confirms for this gesture.
#
# The seat's client PINS the leaf (servercerts/<remote>.crt, in both config dirs incus uses on
# darwin); both copies are backed up and replaced. Moving the client to CA trust is a later
# step. The cluster's own consumers (CAPN's identity Secrets `server-crt`) pin it too: they are
# re-pinned at the cold start, from the servercerts copy this writes.

log() { printf '[incus-cluster-cert] %s\n' "$*" >&2; }
die() {
  printf '[incus-cluster-cert] ERROR: %s\n' "$*" >&2
  exit 1
}

# Exit contract: 0 the cluster is (now) CURRENT, or --dry-run reached the mint · 10 --check found a
# RENEW or REPIN to do · 2 a member is ABSENT · 1 anything that failed. --check classifies only;
# --dry-run runs the real path — classification and preflight — up to the mint and stops there.
# A renewal needed is 10, never 1, so a real failure can never pass for a normal check.
# --debug traces the PUBLIC part only — classification and preflight, after the keys are loaded
# and before the mint — never the reading of keys.yaml nor the mint itself.
force=0 check=0 dryRun=0 debug=0
for arg in "$@"; do
  case "$arg" in
    --force) force=1 ;;
    --check) check=1 ;;
    --dry-run) dryRun=1 ;;
    --debug) debug=1 ;;
    *) die "usage: incus-cluster-cert-renew [--check | --dry-run | --force] [--debug]" ;;
  esac
done

work="$(mktemp -d)"
chmod 700 "$work"
# Every ssh forwards NOTHING: no agent (the seat's ForwardAgent may still say yes), no port.
# And no MULTIPLEXING: with ControlMaster auto, a session rides an existing master — one that may
# have been opened with ForwardAgent yes, which would defeat the option above, and a stale one
# hangs silently. Timeouts so a dead link fails instead of waiting.
# And ONE identity, stated here and not taken from the seat's ssh config or its agent: the
# operator principal's key and certificate, fixed at evaluation (no agent is consulted at all).
sshq() {
  ssh -o IdentityAgent=none -o IdentitiesOnly=yes -o IdentityFile="$sshKey" -o CertificateFile="$sshCert" \
    -o User="$sshUser" -o ForwardAgent=no -o ClearAllForwardings=yes -o ControlMaster=no -o ControlPath=none \
    -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=2 "$@"
}

# On a NixOS member, the SETUID sudo is the wrapper; a non-interactive ssh PATH finds the plain,
# non-setuid copy in /run/current-system/sw/bin first, which refuses to run.
rsudo=/run/wrappers/bin/sudo

remoteDir=""
cleanup() {
  rm -rf "$work"
  if [[ -n $remoteDir ]]; then
    sshq "$via" "rm -rf '$remoteDir'" >/dev/null 2>&1 || log "WARN: could not remove $remoteDir on $via — remove it by hand"
  fi
}
trap cleanup EXIT

# --- The authority's signing slot, never materialised ---------------------------------------
# keys.yaml is decrypted straight into yq through a PIPE, and only the signing slot of this
# authority comes out: the fleet's other privates are never held in a variable, and nothing
# goes through a here-string, which bash may back with a temporary FILE.
log "reading ${authority} from keys.yaml (piped, nothing written)"
selected="$(sops --decrypt --input-type yaml --output-type yaml "$keysYaml" | yq -o=json "
  .authorities.\"${authority}\" as \$a
  | ((\$a.slots // {}) | to_entries | sort_by(.key)
     | map(select((.value.compromised // \"\") == \"\")) | .[0]) as \$s
  | {\"usage\": ((\$a.usage // []) | join(\",\")), \"slot\": (\$s.key // \"\"),
     \"ca\": (\$s.value.ca_crt // \"\"), \"key\": (\$s.value.private // \"\")}")" ||
  die "cannot decrypt keys.yaml — is the operator's sops age key available on this seat?"
field() { printf '%s' "$selected" | yq -r ".$1"; }
usage="$(field usage)"
slot="$(field slot)"
caCrt="$(field ca)"
caKey="$(field key)"
unset selected
[[ ,${usage}, == *,tls-authority,* ]] || die "${authority} does not advertise tls-authority"
# The signing slot: the oldest one not marked compromised (keys.schema.yaml, authoritySlots).
[[ -n $slot ]] || die "${authority} has no slot that may sign"
[[ -n $caCrt && -n $caKey ]] || die "${authority}@${slot} lacks its ca_crt or its private"
printf '%s\n' "$caCrt" >"$work/ca.crt"
caFp="$(openssl x509 -noout -fingerprint -sha1 -in "$work/ca.crt" | sed -e 's/.*=//' -e 's/://g')"
log "signing slot ${authority}@${slot}, root ${caFp}"
if ((debug == 1)); then set -x; fi

# --- Three cases, decided before anything changes --------------------------------------------
#   CURRENT  every name serves a leaf that chains to this root, names itself, carries every SAN,
#            is valid for 30 more days, and is the leaf the client pins → nothing to do;
#   RENEW    every name answers, but with the wrong certificate: the old root's leaf, incus's own
#            self-signed one after a re-init, a missing SAN, an expiry near, a stale pin;
#   ABSENT   a name does not answer on 8443 — the cluster is not up, or a member is offline.
#            `update-certificate` needs every member ONLINE, so this refuses and changes nothing.
# Both answer EMPTY when <name> serves nothing — never fail: under errexit + pipefail a failing
# probe would end the run silently instead of reporting the member ABSENT.
served() { # <name> → sha256 of the leaf <name>:8443 presents, or nothing
  { openssl s_client -connect "$1:8443" -servername "$1" </dev/null 2>/dev/null |
    openssl x509 -noout -fingerprint -sha256 2>/dev/null | sed -e 's/.*=//'; } || true
}
servedPem() { # <name> → the PEM of the leaf <name>:8443 presents, or nothing
  { openssl s_client -connect "$1:8443" -servername "$1" </dev/null 2>/dev/null | openssl x509 2>/dev/null; } || true
}
absent=() reasons=()
for name in "${verifyNames[@]}"; do
  pem="$(servedPem "$name")"
  if [[ -z $pem ]]; then
    absent+=("$name")
    continue
  fi
  verdict="$(openssl s_client -connect "$name:8443" -servername "$name" -verify_hostname "$name" \
    -CAfile "$work/ca.crt" </dev/null 2>/dev/null | grep -E '^Verification' || true)"
  [[ $verdict == "Verification: OK" ]] || reasons+=("${name}: does not chain to ${caFp} or does not name itself (${verdict:-no verification})")
  sanText="$(openssl x509 -noout -ext subjectAltName <<<"$pem" 2>/dev/null | tr -d ' ' | tr ',' '\n')"
  for s in "${sans[@]}"; do
    grep -qxiE "(DNS|IPAddress):${s//./\\.}" <<<"$sanText" ||
      { [[ $s == "::1" ]] && grep -qx 'IPAddress:0:0:0:0:0:0:0:1' <<<"$sanText"; } ||
      reasons+=("${name}: SAN ${s} missing")
  done
  openssl x509 -noout -checkend $((30 * 86400)) <<<"$pem" >/dev/null || reasons+=("${name}: expires within 30 days")
done
if ((${#absent[@]} > 0)); then
  printf '[incus-cluster-cert] ABSENT: no certificate served on %s (port 8443). Every member must be ONLINE: bring incus up on every member, then run again. Nothing was changed.\n' "${absent[*]}" >&2
  exit 2
fi

# ONE certificate serves every member: two different leaves is a half-done update.
current="$(served "${verifyNames[0]}")"
for name in "${verifyNames[@]}"; do
  [[ "$(served "$name")" == "$current" ]] || reasons+=("${name}: serves a different leaf than ${verifyNames[0]}")
done

pinReasons=()
pins=()
for dir in "$HOME/.config/incus/servercerts" "$HOME/Library/Application Support/incus/servercerts"; do
  if [[ -f "$dir/${remote}.crt" ]]; then pins+=("$dir/${remote}.crt"); fi
done
for pin in "${pins[@]}"; do
  [[ "$(openssl x509 -noout -fingerprint -sha256 -in "$pin" | sed -e 's/.*=//')" == "$current" ]] ||
    pinReasons+=("client pin ${pin} is not the served leaf")
done

repin() { # <pem file> — back up and replace every pin of the seat's client
  local pin
  for pin in "${pins[@]}"; do
    cp -p "$pin" "${pin}.bak.$(date +%s)"
    chmod 600 "${pin}".bak.*
    install -m 0644 "$1" "$pin"
    log "re-pinned ${pin}"
  done
}

verify() { # <expected leaf sha256> — every name serves it, chaining to the root, by name
  local name fp verdict failures=0
  for name in "${verifyNames[@]}"; do
    fp="$(served "$name")"
    verdict="$(openssl s_client -connect "$name:8443" -servername "$name" -verify_hostname "$name" \
      -CAfile "$work/ca.crt" </dev/null 2>/dev/null | grep -E '^Verification' || true)"
    if [[ $fp == "$1" && $verdict == "Verification: OK" ]]; then
      log "ok   ${name}: the leaf chains to ${caFp}, name verified"
    else
      log "FAIL ${name}: served ${fp:-nothing}; ${verdict:-no verification}"
      failures=$((failures + 1))
    fi
  done
  if incus cluster list "${remote}:" >/dev/null 2>&1; then
    log "ok   incus cluster list ${remote}: through the client"
  else
    log "FAIL incus cluster list ${remote}: through the client"
    failures=$((failures + 1))
  fi
  ((failures == 0)) || die "${failures} verification(s) failed"
}

# Read-only preflight of the install path, so the operator knows before the real run. The SAME
# remote probe runs on every member (each may be restarted), testing the EXACT commands the
# install uses, and every line it prints is tagged OK, PROMPT or ERROR. Any ERROR stops the run
# before anything is minted.
probe='rsudo="$1"
if out="$("$rsudo" -n true 2>&1)"; then echo "OK $rsudo runs without a password"
else case "$out" in
  *"must be owned by uid 0"*|*setuid*) echo "ERROR $rsudo is not the setuid sudo: $out" ;;
  *"password is required"*|*"a terminal is required"*) echo "PROMPT $rsudo will ask for your password (ssh -t)" ;;
  *) echo "ERROR $rsudo -n true failed: $out" ;;
esac; fi
command -v incus >/dev/null && echo "OK incus on PATH" || echo "ERROR incus not on PATH"
d="/run/user/$(id -u)"
[ -d "$d" ] && echo "OK $d present (tmpfs)" || echo "ERROR $d absent — the key would have nowhere safe to go"'
preflightErrors=0
preflight() {
  local m line f
  for f in "$sshKey" "$sshCert"; do
    if [[ -r $f ]]; then
      log "  OK $f readable (the operator identity)"
    else
      log "  ERROR $f missing or unreadable — sshq has no identity"
      preflightErrors=$((preflightErrors + 1))
    fi
  done
  for m in "${members[@]}"; do
    log "preflight on ${m}:"
    # stdout carries the tagged probe lines; ssh's own stderr (its KnownHostsCommand logs
    # included) is shown only when the connection fails.
    if ! line="$(sshq -o BatchMode=yes "$m" "sh -c '$probe' sh $rsudo" 2>"$work/ssh.err")"; then
      log "  ERROR ${m}: unreachable over ssh ($(grep -v -F 'ndh::logger' "$work/ssh.err" | tail -2 | tr '\n' ' '))"
      preflightErrors=$((preflightErrors + 1))
      continue
    fi
    while IFS= read -r line; do
      [[ -n $line ]] || continue
      log "  ${line}"
      if [[ $line == ERROR* ]]; then preflightErrors=$((preflightErrors + 1)); fi
    done <<<"$line"
  done
  return 0
}

if ((${#reasons[@]} == 0 && ${#pinReasons[@]} == 0 && force == 0)); then
  log "CURRENT: every name serves a leaf of ${authority}@${slot} with the full SAN set, and the client pins it — nothing to do (--force to re-mint)"
  exit 0
fi

# Only the pins are stale — the served leaf is right (e.g. a run interrupted between the
# update and the re-pin): re-pin from it, never re-mint, so a rerun does not churn the cluster.
if ((${#reasons[@]} == 0 && force == 0)); then
  log "REPIN: the cluster is current, the client is not:"
  for r in "${pinReasons[@]}"; do log "  - ${r}"; done
  ((check == 0)) || exit 10
  if ((dryRun == 1)); then
    log "DRY RUN: would re-pin the client from the served leaf — stopping here"
    exit 0
  fi
  servedPem "${verifyNames[0]}" >"$work/served.crt"
  repin "$work/served.crt"
  verify "$current"
  exit 0
fi

if ((${#reasons[@]} > 0)); then
  log "RENEW:"
  for r in "${reasons[@]}" "${pinReasons[@]}"; do log "  - ${r}"; done
else
  log "RENEW (--force): the cluster is current, re-minting anyway"
fi
preflight
((preflightErrors == 0)) || die "preflight found ${preflightErrors} error(s) — nothing was minted or changed"
((check == 0)) || exit 10
if ((dryRun == 1)); then
  log "DRY RUN: would mint a ${days}d cluster leaf CN=${cn} with ${#sans[@]} SANs and install it through ${via} — stopping here"
  exit 0
fi

{ set +x; } 2>/dev/null

# --- Mint -----------------------------------------------------------------------------------
sanArgs=()
for s in "${sans[@]}"; do sanArgs+=(--san "$s"); done
log "minting a ${days}d cluster leaf CN=${cn} with ${#sans[@]} SANs"
step certificate create "$cn" "$work/leaf.crt" "$work/leaf.key" \
  --ca "$work/ca.crt" --ca-key <(printf '%s\n' "$caKey") \
  --no-password --insecure --not-after "$((days * 24))h" "${sanArgs[@]}" >/dev/null ||
  die "step certificate create failed"
unset caKey
chmod 600 "$work/leaf.key"
step certificate verify "$work/leaf.crt" --roots "$work/ca.crt" >/dev/null ||
  die "the minted leaf does not chain to ${authority}@${slot}"
leafFp="$(openssl x509 -noout -fingerprint -sha256 -in "$work/leaf.crt" | sed -e 's/.*=//')"
log "minted leaf sha256 ${leafFp}"

# --- Install through ONE member's local socket ----------------------------------------------
log "installing through ${via}'s local socket (every member must be ONLINE)"
log "opening a private tmpfs directory on ${via}…"
remoteDir="$(sshq "$via" 'd="/run/user/$(id -u)"; [ -d "$d" ] || exit 3; umask 077; mktemp -d "$d/incus-cluster-cert.XXXXXX"')" ||
  die "cannot open a private tmpfs directory on ${via} (/run/user/<uid> is required — the key never goes to a disk-backed /tmp)"
log "sending the leaf to ${via}…"
sshq "$via" "cat > '$remoteDir/leaf.crt'" <"$work/leaf.crt" || die "cannot send the leaf to ${via}"
log "sending the leaf KEY to ${via}…"
sshq "$via" "cat > '$remoteDir/leaf.key'" <"$work/leaf.key" || die "cannot send the key to ${via}"
log "running update-certificate on ${via} — sudo may prompt for your password NOW"
sshq -t "$via" "$rsudo incus cluster update-certificate '$remoteDir/leaf.crt' '$remoteDir/leaf.key'" ||
  die "incus cluster update-certificate failed on ${via} — check \`sudo incus cluster list\` there"
log "removing the leaf and its key from ${via}…"
if sshq "$via" "rm -rf '$remoteDir'"; then remoteDir=""; else log "WARN: could not remove $remoteDir on $via yet — the exit trap retries"; fi

# --- Every member serves the new leaf, restarting the ones that do not ---------------------
for member in "${members[@]}"; do
  if [[ "$(served "$member")" != "$leafFp" ]]; then
    log "${member} still serves the old leaf — restarting its incus daemon (sudo may prompt NOW)"
    sshq -t "$member" "$rsudo systemctl restart incus" || die "cannot restart incus on ${member}"
    sleep 5
  fi
done

repin "$work/leaf.crt"
verify "$leafFp"

cat <<EOF >&2
[incus-cluster-cert] done. The cluster serves the new leaf on every name, chaining to ${authority}@${slot}.
[incus-cluster-cert] At the cold start (T4): CAPN's identity Secrets pin \`server-crt\` — re-pin them with
[incus-cluster-cert]   $HOME/.config/incus/servercerts/${remote}.crt  (the new leaf, sha256 ${leafFp})
[incus-cluster-cert] NOT refreshed here: an incus client on nikopol, if one pins the cluster — re-pin it from that file.
EOF
