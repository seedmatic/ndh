# ★ xtrace-guard — no trace, whatever the invocation (bash -x, an inherited SHELLOPTS=xtrace, a
# caller's set -x): this script handles private keys, and a trace prints every value it expands.
case $- in *x*) { set +x; } 2>/dev/null; echo "[xtrace-guard] xtrace disabled: this script handles private keys" >&2 ;; esac
export -n SHELLOPTS 2>/dev/null || true # readonly in bash, so not unset; un-exported, it stops at this process
unset NDH_LOGGER_XTRACE # ndh::logger:command:run traces its command only when this is 1
unset BASH_XTRACEFD 2>/dev/null || true

# incus-cluster-cert-renew — renew the Incus CLUSTER certificate under the authority's CURRENT
# signing slot, on the cluster's OWN key, install it on every member, re-pin the operator seat's client, verify.
#
# Built BY REVISION and run by the operator from the operator seat (the hotfix rule): the SAN set,
# the members, the names to verify and the ENCRYPTED keys.yaml are fixed at evaluation —
# nothing evaluates a working tree at run time.
#
# ★ Nothing of ours generates a key (docs/ssh-keys-architecture.adoc, principle "no key generated at
# activation"): the cluster keeps the key Incus generated. On ONE member, as root, step-cli writes a
# CSR on /var/lib/incus/cluster.key into a 0700 dir on its tmpfs (/run/user/<uid>); only that CSR
# (public) comes to the operator seat, which checks it names EXACTLY the fleet's names and carries the key the
# cluster serves, then signs it with a pinned leaf profile; only the certificate (public) goes back,
# installed with the same key through the member's LOCAL unix socket (`sudo incus cluster
# update-certificate`). The authority's private is never written: sops is piped and step-cli reads it
# through process substitution. Each signed leaf is recorded in the operator seat's ledger.
#
# ★ ONE certificate serves every member: `update-certificate` installs it cluster-wide. A
# member still serving the old leaf after the update is restarted (`systemctl restart incus`) —
# safe only while the members run no instance, which the operator confirms for this gesture.
#
# The operator seat's client PINS the leaf (servercerts/<remote>.crt, in both config dirs incus uses on
# darwin); both copies are backed up and replaced. Moving the client to CA trust is a later
# step. The cluster's own consumer, CAPN, pins NOTHING: rke2lab renders its identity Secrets
# without `server-crt`, so the provider verifies the leaf by NAME against the TLS authority's root,
# which its pod trusts — a renewal needs no re-pin there.

log() { printf '[incus-cluster-cert] %s\n' "$*" >&2; }
die() {
  printf '[incus-cluster-cert] ERROR: %s\n' "$*" >&2
  exit 1
}

# Exit contract: 0 the cluster is (now) CURRENT, or --dry-run reached the signature · 10 --check found a
# RENEW or REPIN to do · 2 a member is ABSENT · 1 anything that failed. --check classifies only;
# --dry-run runs the real path — classification and preflight — up to the signature and stops there.
# A renewal needed is 10, never 1, so a real failure can never pass for a normal check.
# No mode traces: this script holds the authority's private, and its steps are logged by name only.
#
# --activation: the step bioskop's darwin activation runs (the operator launches the switch, so it
# stays a gesture). It acts ONLY on a wrong issuer, a missing fleet name or diverging leaves — never on
# an expiry date —, never prompts, and an ABSENT cluster (down, a member away) is a warning, exit 0,
# so the activation goes on.
force=0 check=0 dryRun=0 activation=0
for arg in "$@"; do
  case "$arg" in
    --force) force=1 ;;
    --check) check=1 ;;
    --dry-run) dryRun=1 ;;
    --activation) activation=1 ;;
    *) die "usage: incus-cluster-cert-renew [--check | --dry-run | --force | --activation]" ;;
  esac
done
# An interactive run lets sudo prompt on the member (ssh -t); the activation never prompts.
tty=(-t)
if ((activation == 1)); then tty=(); fi

work="$(mktemp -d)"
chmod 700 "$work"
# Every ssh forwards NOTHING: no agent (the operator seat's ForwardAgent may still say yes), no port.
# And no MULTIPLEXING: with ControlMaster auto, a session rides an existing master — one that may
# have been opened with ForwardAgent yes, which would defeat the option above, and a stale one
# hangs silently. Timeouts so a dead link fails instead of waiting.
# And ONE identity, stated here and not taken from the operator seat's ssh config or its agent: the
# operator principal's key and certificate, fixed at evaluation (no agent is consulted at all).
# -F /dev/null: these options are the whole configuration, so no `Host *` of the operator's can add a
# ProxyJump or a LocalCommand; hosts are still trusted through /etc/ssh/ssh_known_hosts. No password.
sshq() {
  ssh -F /dev/null -o BatchMode=yes -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no \
    -o StrictHostKeyChecking=yes -o IdentityAgent=none -o IdentitiesOnly=yes -o IdentityFile="$sshKey" -o CertificateFile="$sshCert" \
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
  die "cannot decrypt keys.yaml — is the operator's sops age key available on this operator seat?"
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

# --- Three cases, decided before anything changes --------------------------------------------
#   CURRENT  every name serves a leaf that chains to this root, names itself, carries every SAN,
#            is valid for 30 more days, and is the leaf the client pins → nothing to do;
#   RENEW    every name answers, but with the wrong certificate: the old root's leaf, incus's own
#            self-signed one after a re-init, a missing SAN, an expiry near, a stale pin;
#   ABSENT   a name does not answer on 8443 — the cluster is not up, or a member is offline.
#            `update-certificate` needs every member ONLINE, so this refuses and changes nothing.
# Both answer EMPTY when <name> serves nothing — never fail: under errexit + pipefail a failing
# probe would end the run silently instead of reporting the member ABSENT.
# Under a timeout: a name that hangs must not stall an activation.
served() { # <name> → sha256 of the leaf <name>:8443 presents, or nothing
  { timeout 10 openssl s_client -connect "$1:8443" -servername "$1" </dev/null 2>/dev/null |
    openssl x509 -noout -fingerprint -sha256 2>/dev/null | sed -e 's/.*=//'; } || true
}
servedPem() { # <name> → the PEM of the leaf <name>:8443 presents, or nothing
  { timeout 10 openssl s_client -connect "$1:8443" -servername "$1" </dev/null 2>/dev/null | openssl x509 2>/dev/null; } || true
}
absent=() reasons=()
for name in "${verifyNames[@]}"; do
  pem="$(servedPem "$name")"
  if [[ -z $pem ]]; then
    absent+=("$name")
    continue
  fi
  verdict="$(timeout 10 openssl s_client -connect "$name:8443" -servername "$name" -verify_hostname "$name" \
    -CAfile "$work/ca.crt" </dev/null 2>/dev/null | grep -E '^Verification' || true)"
  [[ $verdict == "Verification: OK" ]] || reasons+=("${name}: does not chain to ${caFp} or does not name itself (${verdict:-no verification})")
  sanText="$(openssl x509 -noout -ext subjectAltName <<<"$pem" 2>/dev/null | tr -d ' ' | tr ',' '\n')"
  for s in "${sans[@]}"; do
    grep -qxiE "(DNS|IPAddress):${s//./\\.}" <<<"$sanText" ||
      { [[ $s == "::1" ]] && grep -qx 'IPAddress:0:0:0:0:0:0:0:1' <<<"$sanText"; } ||
      reasons+=("${name}: SAN ${s} missing")
  done
  # A date is never an activation's trigger: the operator renews ahead of time by hand.
  if ((activation == 0)); then
    openssl x509 -noout -checkend $((30 * 86400)) <<<"$pem" >/dev/null || reasons+=("${name}: expires within 30 days")
  fi
done
if ((${#absent[@]} > 0 && activation == 1)); then
  printf '[incus-cluster-cert] WARN: no certificate served on %s (port 8443): the cluster is not up, or a member is away. Nothing changed; run incus-cluster-cert-renew once it is.\n' "${absent[*]}" >&2
  exit 0
fi
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

repin() { # <pem file> — back up and replace every pin of the operator seat's client
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
    verdict="$(timeout 10 openssl s_client -connect "$name:8443" -servername "$name" -verify_hostname "$name" \
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
# before anything is signed.
probe='rsudo="$1"
if out="$("$rsudo" -n true 2>&1)"; then echo "OK $rsudo runs without a password"
else case "$out" in
  *"must be owned by uid 0"*|*setuid*) echo "ERROR $rsudo is not the setuid sudo: $out" ;;
  *"password is required"*|*"a terminal is required"*) echo "PROMPT $rsudo will ask for your password (ssh -t)" ;;
  *) echo "ERROR $rsudo -n true failed: $out" ;;
esac; fi
command -v incus >/dev/null && echo "OK incus on PATH" || echo "ERROR incus not on PATH"
command -v step >/dev/null && echo "OK step on PATH" || echo "ERROR step not on PATH — the CSR cannot be made"
"$rsudo" -n test -s /var/lib/incus/cluster.key && echo "OK /var/lib/incus/cluster.key present" || echo "ERROR /var/lib/incus/cluster.key absent — no cluster key to certify"
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
  log "CURRENT: every name serves a leaf of ${authority}@${slot} with the full SAN set, and the client pins it — nothing to do (--force to renew)"
  exit 0
fi

# Only the pins are stale — the served leaf is right (e.g. a run interrupted between the
# update and the re-pin): re-pin from it, never renew, so a rerun does not churn the cluster.
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
  log "RENEW (--force): the cluster is current, renewing anyway"
fi
preflight
((preflightErrors == 0)) || die "preflight found ${preflightErrors} error(s) — nothing was signed or changed"
((check == 0)) || exit 10
if ((dryRun == 1)); then
  log "DRY RUN: would certify ${via}'s cluster key for ${days}d, CN=${cn} with ${#sans[@]} SANs — stopping here"
  exit 0
fi

# --- A CSR on the cluster's own key, made on ONE member ---------------------------------------
log "opening a private tmpfs directory on ${via}…"
remoteDir="$(sshq "$via" 'd="/run/user/$(id -u)"; [ -d "$d" ] || exit 3; umask 077; mktemp -d "$d/incus-cluster-cert.XXXXXX"')" ||
  die "cannot open a private tmpfs directory on ${via} (/run/user/<uid> is required)"
stepSans=""
for s in "${sans[@]}"; do stepSans+=" --san '$s'"; done
log "asking ${via} for a CSR on its existing cluster key (no key is generated)"
sshq "${tty[@]}" "$via" "$rsudo step certificate create '$cn' '$remoteDir/cluster.csr' --csr --key /var/lib/incus/cluster.key --no-password --insecure $stepSans >/dev/null && $rsudo chown \$(id -u) '$remoteDir/cluster.csr'" ||
  die "${via} could not make a CSR on /var/lib/incus/cluster.key"
sshq "$via" "cat '$remoteDir/cluster.csr'" >"$work/cluster.csr" || die "cannot read the CSR back from ${via}"
openssl req -in "$work/cluster.csr" -noout -verify >/dev/null 2>&1 || die "the CSR from ${via} does not verify"

# The operator seat trusts nothing the CSR claims: its names must be EXACTLY the fleet's, so a member cannot
# obtain a leaf for another host's name or a wildcard, and its key must be the one the cluster serves.
pubOf() { openssl "$1" -in "$2" -noout -pubkey 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | openssl sha256 | sed -e 's/.*= *//'; }
sanSet() { # <x509|req> <file> → its SANs, one per line, normalised, sorted
  openssl "$1" -in "$2" -noout -text 2>/dev/null | grep -A1 'Subject Alternative Name' | tail -1 | tr ',' '\n' |
    sed -e 's/^ *//' -e 's/^DNS://' -e 's/^IP Address://' -e 's/^0:0:0:0:0:0:0:1$/::1/' | sed '/^$/d' | sort -u
}
wanted="$(printf '%s\n' "${sans[@]}" | sort -u)"
[[ "$(sanSet req "$work/cluster.csr")" == "$wanted" ]] ||
  die "the CSR from ${via} does not name exactly the fleet's SANs — refused, nothing signed"
servedPem "${verifyNames[0]}" >"$work/served.crt"
[[ "$(pubOf req "$work/cluster.csr")" == "$(pubOf x509 "$work/served.crt")" ]] ||
  die "the CSR's key is not the key ${verifyNames[0]} serves — refused, nothing signed"

# --- Sign with a pinned leaf profile, the CA key through a file descriptor ------------------
# serverAuth alone, as Incus mints its own cluster certificate: members never check a peer's usage.
cat >"$work/leaf.tpl" <<'TPL'
{
  "subject": {"commonName": {{ toJson .Subject.CommonName }}},
  "sans": {{ toJson .SANs }},
  "keyUsage": ["digitalSignature"],
  "extKeyUsage": ["serverAuth"],
  "basicConstraints": {"isCA": false}
}
TPL
log "signing the CSR for ${days}d with ${authority}@${slot}"
step certificate sign "$work/cluster.csr" "$work/ca.crt" <(printf '%s\n' "$caKey") \
  --template "$work/leaf.tpl" --not-after "$((days * 24))h" >"$work/leaf.crt" 2>"$work/sign.err" ||
  die "step certificate sign failed: $(tail -1 "$work/sign.err")"
unset caKey
step certificate verify "$work/leaf.crt" --roots "$work/ca.crt" >/dev/null ||
  die "the signed leaf does not chain to ${authority}@${slot}"
[[ "$(pubOf x509 "$work/leaf.crt")" == "$(pubOf req "$work/cluster.csr")" ]] || die "the signed leaf does not carry the CSR's key"
leafFp="$(openssl x509 -noout -fingerprint -sha256 -in "$work/leaf.crt" | sed -e 's/.*=//')"
log "signed leaf sha256 ${leafFp}"

# --- The record: the operator seat's ledger -----------------------------------------------------------
ledger="${XDG_STATE_HOME:-$HOME/.local/state}/ndh/incus-cluster-cert"
mkdir -p "$ledger"
{
  printf '# sha256 %s\n# signed %s by %s@%s for %s\n' "$leafFp" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$authority" "$slot" "$cn"
  cat "$work/leaf.crt"
} >"$ledger/${leafFp//:/}.crt"
log "recorded in ${ledger}/${leafFp//:/}.crt"

# --- Install through ONE member's local socket, with the key it already holds ---------------
log "sending the leaf (public) to ${via}…"
sshq "$via" "cat > '$remoteDir/leaf.crt'" <"$work/leaf.crt" || die "cannot send the leaf to ${via}"
log "running update-certificate on ${via} with its existing cluster key"
sshq "${tty[@]}" "$via" "$rsudo incus cluster update-certificate '$remoteDir/leaf.crt' /var/lib/incus/cluster.key" ||
  die "incus cluster update-certificate failed on ${via} — check \`sudo incus cluster list\` there"
if sshq "$via" "rm -rf '$remoteDir'"; then remoteDir=""; else log "WARN: could not remove $remoteDir on $via yet — the exit trap retries"; fi

# --- Every member serves the new leaf, restarting the ones that do not ---------------------
for member in "${members[@]}"; do
  if [[ "$(served "$member")" != "$leafFp" ]]; then
    log "${member} still serves the old leaf — restarting its incus daemon (sudo may prompt NOW)"
    sshq "${tty[@]}" "$member" "$rsudo systemctl restart incus" || die "cannot restart incus on ${member}"
    sleep 5
  fi
done

repin "$work/leaf.crt"
verify "$leafFp"

cat <<EOF >&2
[incus-cluster-cert] done. The cluster serves the new leaf on every name, chaining to ${authority}@${slot}.
[incus-cluster-cert] CAPN needs nothing: it verifies the leaf by name against ${authority}'s root, no pin.
[incus-cluster-cert] NOT refreshed here: an incus client on nikopol, if one pins the cluster — re-pin it from
[incus-cluster-cert]   $HOME/.config/incus/servercerts/${remote}.crt  (the new leaf, sha256 ${leafFp})
EOF
