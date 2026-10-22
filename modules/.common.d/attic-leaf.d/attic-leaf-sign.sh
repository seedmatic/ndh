# ★ xtrace-guard — no trace, whatever the invocation (bash -x, an inherited SHELLOPTS=xtrace, a
# caller's set -x): this script handles private keys, and a trace prints every value it expands.
case $- in *x*) { set +x; } 2>/dev/null; echo "[xtrace-guard] xtrace disabled: this script handles private keys" >&2 ;; esac
export -n SHELLOPTS 2>/dev/null || true # readonly in bash, so not unset; un-exported, it stops at this process
unset NDH_LOGGER_XTRACE # ndh::logger:command:run traces its command only when this is 1
unset BASH_XTRACEFD 2>/dev/null || true
unset BASH_ENV # a caller's BASH_ENV holding `set -x` would trace every child bash this script starts

# None of these tools comes from the caller's shell, nor does the locale: the PATH is this package's store
# paths, then the system's own directories (logger), and LC_ALL is C, whatever the caller's PATH, LANG or
# POSIXLY_CORRECT (which makes awk compare strings by collation). What they print is compared and signed.
PATH="$toolPath:/usr/bin:/bin"
export PATH LC_ALL=C
unset POSIXLY_CORRECT GREP_OPTIONS

# attic-leaf-sign — certify each cache container's TLS key under the authority's CURRENT signing
# slot, install the leaf on its NixOS guest, verify — the model of incus-cluster-cert-renew (S6).
#
# Built BY REVISION and run by the operator from the operator seat (the hotfix rule): the caches, their
# names, their guests and the ENCRYPTED keys.yaml are fixed at evaluation — nothing evaluates a
# working tree at run time.
#
# ★ No key is generated here: each cache container generated its own once (attic-tls-key, never
# regenerated while present) and wrote a CSR beside it. Only that CSR (public) comes to the operator
# seat, which checks it names EXACTLY the cache's fabric name and carries the key the cache serves,
# then signs it with a pinned leaf profile; only the certificate (public) goes back, into the
# dataset on the guest, where the container takes it by itself (attic-tls-leaf.path). The
# authority's private is never written nor held: only the signing step decrypts it, that one slot's,
# into step-cli through process substitution; every other path reads cleartext metadata only. Each signed leaf is recorded in the operator seat's ledger.

# stderr goes to the log sink (below); each message is also written to the invoking console.
log() {
  printf '[attic-leaf] %s\n' "$*" >&2
  ndh::logger:notice "[attic-leaf] $*"
}
die() {
  printf '[attic-leaf] ERROR: %s\n' "$*" >&2
  ndh::logger:notice "[attic-leaf] ERROR: $*"
  exit 1
}

# Every run is logged under its tag, so whether an activation decrypted or signed is answerable from
# the unified log, not only from the activation's output: the script re-runs itself ONCE inside
# ndh::logger:command:run, which sends its stderr to the sink and keeps the console on fd 3. The
# exit status is the re-run's.
if [[ -z ${NDH_ATTIC_LEAF_SIGN_LOGGED:-} ]]; then
  export NDH_ATTIC_LEAF_SIGN_LOGGED=1
  ndh::logger:command:run "$loggerTag" bash "${BASH_SOURCE[0]}" "$@"
  exit 0
fi

# Exit contract: 0 every cache is (now) CURRENT, ordie "usage: attic-leaf-sign [--check | --dry-run | --force | --activation]"reached the signature · 10 --check found a
# leaf to sign · 2 a cache is ABSENT · 1 anything that failed. --check classifies only; --dry-run runs
# the real path — classification and preflight — up to the signature and stops there. A signature
# needed is 10, never 1, so a real failure can never pass for a normal check. There is no trace mode:
# the CA private is held in this shell, and an xtrace on any line after its loading is one edit away
# from printing it (🛡️ R1); the steps are logged instead.
#
# --activation: the step bioskop's darwin activation runs (the operator launches the switch, so it
# stays a gesture). It acts ONLY on a missing leaf, a wrong issuer or a missing name — never on an
# expiry date —, never prompts, and an ABSENT cache (its container not up, its guest away) is a
# warning, exit 0, so the activation goes on.
force=0 check=0 dryRun=0 activation=0
for arg in "$@"; do
  case "$arg" in
    --force) force=1 ;;
    --check) check=1 ;;
    --dry-run) dryRun=1 ;;
    --activation) activation=1 ;;
    *) die "usage: attic-leaf-sign [--check | --dry-run | --force | --activation]" ;;
  esac
done
# An interactive run lets sudo prompt on the guest (ssh -t); the activation never prompts.
tty=(-t)
if ((activation == 1)); then tty=(); fi

if ((${#fqdns[@]} == 0)); then
  log "no NixOS guest declares a cache container (ndh.atticCache) — nothing to sign"
  exit 0
fi

work="$(mktemp -d)"
chmod 700 "$work"
# Every ssh forwards NOTHING: no agent (the operator seat's ForwardAgent may still say yes), no port.
# And no MULTIPLEXING: with ControlMaster auto, a session rides an existing master — one that may
# have been opened with ForwardAgent yes, which would defeat the option above, and a stale one
# hangs silently. Timeouts so a dead link fails instead of waiting.
# And ONE identity, stated here and not taken from the operator seat's ssh config or its agent: the
# operator principal's key and certificate, fixed at evaluation (no agent is consulted at all).
# And NO ssh config (-F /dev/null), so a `Host *` block cannot add a ProxyJump, a ProxyCommand or a
# LocalCommand, and no prompt of ssh's own; the host is trusted only through the default global
# known-hosts file, which carries the fleet's @cert-authority lines (as S2's push).
sshq() {
  ssh -F /dev/null -o BatchMode=yes -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no \
    -o StrictHostKeyChecking=yes -o IdentityAgent=none -o IdentitiesOnly=yes -o IdentityFile="$sshKey" -o CertificateFile="$sshCert" \
    -o User="$sshUser" -o ForwardAgent=no -o ClearAllForwardings=yes -o ControlMaster=no -o ControlPath=none \
    -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=2 "$@"
}

# On a NixOS guest, the SETUID sudo is the wrapper; a non-interactive ssh PATH finds the plain,
# non-setuid copy in /run/current-system/sw/bin first, which refuses to run.
rsudo=/run/wrappers/bin/sudo

remoteDir="" remoteVia=""
cleanup() {
  rm -rf "$work"
  if [[ -n $remoteDir ]]; then
    sshq "$remoteVia" "rm -rf '$remoteDir'" >/dev/null 2>&1 || log "WARN: could not remove $remoteDir on $remoteVia — remove it by hand"
  fi
}
trap cleanup EXIT

# --- The authority's signing slot, read from keys.yaml's CLEARTEXT fields --------------------
# usage, the slots, `compromised` and `ca_crt` are stored in clear, only `private` is ENC[]: the
# classification, the preflight, --check, --dry-run and a run with nothing to sign never decrypt.
# The private is decrypted once a signature is certain, below (🛡️, 2026-10-17).
log "reading ${authority} from keys.yaml (cleartext metadata, nothing decrypted)"
clear="$(yq -o=json "
  .authorities.\"${authority}\" as \$a
  | ((\$a.slots // {}) | to_entries | sort_by(.key)
     | map(select((.value.compromised // \"\") == \"\")) | .[0]) as \$s
  | {\"usage\": ((\$a.usage // []) | join(\",\")), \"slot\": (\$s.key // \"\"),
     \"ca\": (\$s.value.ca_crt // \"\")}" "$keysYaml")" || die "cannot read ${keysYaml}"
field() { printf '%s' "$clear" | yq -r ".$1"; }
usage="$(field usage)"
slot="$(field slot)"
caCrt="$(field ca)"
unset clear
[[ ,${usage}, == *,tls-authority,* ]] || die "${authority} does not advertise tls-authority"
# The signing slot: the oldest one not marked compromised (keys.schema.yaml, authoritySlots).
[[ -n $slot ]] || die "${authority} has no slot that may sign"
[[ $caCrt == "-----BEGIN CERTIFICATE-----"* ]] || die "${authority}@${slot} has no cleartext ca_crt"
printf '%s\n' "$caCrt" >"$work/ca.crt"
caFp="$(openssl x509 -noout -fingerprint -sha1 -in "$work/ca.crt" | sed -e 's/.*=//' -e 's/://g')"
log "signing slot ${authority}@${slot}, root ${caFp}"

# --- Three cases per cache, decided before anything changes ---------------------------------
#   CURRENT  its name serves a leaf that chains to this root, names itself and nothing else, and is
#            valid for 30 more days → nothing to do;
#   SIGN     the name serves no leaf yet while the guest holds the cache's CSR (its first leaf), or
#            the wrong certificate: another root's, a wrong or extra name, an expiry near;
#   ABSENT   the guest holds no CSR, or cannot be reached: the cache container is not up.
# Both probes answer EMPTY when <name> serves nothing — never fail: under errexit + pipefail a
# failing probe would end the run silently instead of reporting the cache. Under a timeout: a name
# that hangs must not stall an activation.
served() { # <name> → sha256 of the leaf <name>:443 presents, or nothing
  { timeout 10 openssl s_client -connect "$1:443" -servername "$1" </dev/null 2>/dev/null |
    openssl x509 -noout -fingerprint -sha256 2>/dev/null | sed -e 's/.*=//'; } || true
}
servedPem() { # <name> → the PEM of the leaf <name>:443 presents, or nothing
  { timeout 10 openssl s_client -connect "$1:443" -servername "$1" </dev/null 2>/dev/null | openssl x509 2>/dev/null; } || true
}
chains() { # <name> → "Verification: OK" when the leaf chains to this root only, and names <name>
  { timeout 10 openssl s_client -connect "$1:443" -servername "$1" -verify_hostname "$1" -verify_return_error \
    -CAfile "$work/ca.crt" -no-CApath -no-CAstore </dev/null 2>/dev/null | grep -E '^Verification' || true; } || true
}
sanSet() { # <x509|req> <file> → its SANs, one per line, normalised, sorted
  openssl "$1" -in "$2" -noout -text 2>/dev/null | grep -A1 'Subject Alternative Name' | tail -1 | tr ',' '\n' |
    sed -e 's/^ *//' -e 's/^DNS://' | sed '/^$/d' | sort -u
}
pubOf() { openssl "$1" -in "$2" -noout -pubkey 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | openssl sha256 | sed -e 's/.*= *//'; }
hasCsr() { # <via> → 0 when the guest holds the cache's CSR
  sshq -o BatchMode=yes "$1" "$rsudo -n test -s '$hostTls/request.csr'" >/dev/null 2>&1
}

absent=() toSign=()
declare -A reasons=()
for i in "${!fqdns[@]}"; do
  name="${fqdns[$i]}"
  pem="$(servedPem "$name")"
  if [[ -z $pem ]]; then
    if hasCsr "${vias[$i]}"; then
      reasons[$i]="${name}: serves no leaf yet (its first)"
    else
      absent+=("$name")
    fi
    continue
  fi
  printf '%s\n' "$pem" >"$work/served-$i.crt"
  r=""
  verdict="$(chains "$name")"
  [[ $verdict == "Verification: OK" ]] || r+="${name}: does not chain to ${caFp} or does not name itself (${verdict:-no verification}); "
  [[ "$(sanSet x509 "$work/served-$i.crt")" == "$name" ]] || r+="${name}: names more or other than itself; "
  # A date is never an activation's trigger: the operator renews ahead of time by hand.
  if ((activation == 0)); then
    openssl x509 -noout -checkend $((30 * 86400)) <<<"$pem" >/dev/null || r+="${name}: expires within 30 days; "
  fi
  if [[ -n $r ]]; then reasons[$i]="${r%; }"; fi
done
if ((${#absent[@]} > 0 && activation == 1)); then
  printf '[attic-leaf] WARN: no leaf served and no CSR held for %s: the cache container is not up, or its guest is away. Skipped; run attic-leaf-sign once it is.\n' "${absent[*]}" >&2
elif ((${#absent[@]} > 0)); then
  printf '[attic-leaf] ABSENT: no leaf served and no CSR held for %s. Bring the cache container up (ndh-incus-container create/deliver attic), then run again. Nothing was changed.\n' "${absent[*]}" >&2
  exit 2
fi

for i in "${!fqdns[@]}"; do
  if [[ -n ${reasons[$i]:-} ]]; then
    toSign+=("$i")
  elif ((force == 1)) && [[ -f "$work/served-$i.crt" ]]; then
    reasons[$i]="${fqdns[$i]}: current, signing anyway (--force)"
    toSign+=("$i")
  fi
done
if ((${#toSign[@]} == 0)); then
  log "CURRENT: every cache serves a leaf of ${authority}@${slot} naming itself alone — nothing to do (--force to renew)"
  exit 0
fi
log "SIGN:"
for i in "${toSign[@]}"; do log "  - ${reasons[$i]}"; done

# Read-only preflight of the install path, so the operator knows before the real run. The SAME
# remote probe runs on every guest to sign for, testing the EXACT commands the install uses, and
# every line it prints is tagged OK, PROMPT or ERROR. Any ERROR stops the run before anything is
# signed.
probe='rsudo="$1" tls="$2"
if out="$("$rsudo" -n true 2>&1)"; then echo "OK $rsudo runs without a password"
else case "$out" in
  *"must be owned by uid 0"*|*setuid*) echo "ERROR $rsudo is not the setuid sudo: $out" ;;
  *"password is required"*|*"a terminal is required"*) echo "PROMPT $rsudo will ask for your password (ssh -t)" ;;
  *) echo "ERROR $rsudo -n true failed: $out" ;;
esac; fi
"$rsudo" -n test -s "$tls/request.csr" && echo "OK $tls/request.csr present" || echo "ERROR $tls/request.csr absent — the cache container wrote no CSR"
"$rsudo" -n test -d "$tls" -a -w "$tls" && echo "OK $tls writable" || echo "ERROR $tls not writable — the leaf has nowhere to go"
d="/run/user/$(id -u)"
[ -d "$d" ] && echo "OK $d present (tmpfs)" || echo "ERROR $d absent — the leaf would have nowhere to wait"'
preflightErrors=0
preflight() {
  local i line f
  for f in "$sshKey" "$sshCert"; do
    if [[ -r $f ]]; then
      log "  OK $f readable (the operator identity)"
    else
      log "  ERROR $f missing or unreadable — sshq has no identity"
      preflightErrors=$((preflightErrors + 1))
    fi
  done
  for i in "${toSign[@]}"; do
    log "preflight on ${vias[$i]}:"
    # stdout carries the tagged probe lines; ssh's own stderr (its KnownHostsCommand logs
    # included) is shown only when the connection fails.
    if ! line="$(sshq -o BatchMode=yes "${vias[$i]}" "sh -c '$probe' sh $rsudo $hostTls" 2>"$work/ssh.err")"; then
      log "  ERROR ${vias[$i]}: unreachable over ssh ($(grep -v -F 'ndh::logger' "$work/ssh.err" | tail -2 | tr '\n' ' '))"
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
preflight
((preflightErrors == 0)) || die "preflight found ${preflightErrors} error(s) — nothing was signed or changed"
((check == 0)) || exit 10
if ((dryRun == 1)); then
  for i in "${toSign[@]}"; do log "DRY RUN: would certify ${fqdns[$i]}'s key for ${days}d — stopping here"; done
  exit 0
fi

# --- The pinned leaf profile: digitalSignature alone for an ECDSA key, serverAuth, never a CA ---
cat >"$work/leaf.tpl" <<'TPL'
{
  "subject": {"commonName": {{ toJson .Subject.CommonName }}},
  "sans": {{ toJson .SANs }},
  "keyUsage": ["digitalSignature"],
  "extKeyUsage": ["serverAuth"],
  "basicConstraints": {"isCA": false}
}
TPL
ledger="${XDG_STATE_HOME:-$HOME/.local/state}/ndh/attic-leaf"
mkdir -p "$ledger"

for i in "${toSign[@]}"; do
  name="${fqdns[$i]}" via="${vias[$i]}"

  # --- The CSR the cache container wrote beside its key ---------------------------------------
  sshq "$via" "$rsudo -n cat '$hostTls/request.csr'" >"$work/$i.csr" || die "cannot read ${name}'s CSR from ${via}"
  openssl req -in "$work/$i.csr" -noout -verify >/dev/null 2>&1 || die "${name}'s CSR from ${via} does not verify"

  # The operator seat trusts nothing the CSR claims: it must name EXACTLY the cache's fabric name, so a
  # guest cannot obtain a leaf for another name or a wildcard, its subject must be that name, and its
  # key must be the one the cache serves when it serves one. A first leaf has no served key to compare:
  # the container's attic-tls-key refuses a leaf that does not certify its key, and the verification
  # below requires the served leaf to be the one signed here.
  [[ "$(sanSet req "$work/$i.csr")" == "$name" ]] || die "${name}'s CSR does not name exactly ${name} — refused, nothing signed"
  [[ "$(openssl req -in "$work/$i.csr" -noout -subject -nameopt RFC2253 2>/dev/null)" == "subject=CN=${name}" ]] ||
    die "${name}'s CSR subject is not CN=${name} — refused, nothing signed"
  if [[ -f "$work/served-$i.crt" ]]; then
    [[ "$(pubOf req "$work/$i.csr")" == "$(pubOf x509 "$work/served-$i.crt")" ]] ||
      die "${name}'s CSR key is not the key it serves — refused, nothing signed"
  fi

  # --- Sign with the pinned profile, the CA key through a file descriptor ---------------------
  log "signing ${name}'s CSR for ${days}d with ${authority}@${slot}"
  # The only sops call: everything before it reads cleartext metadata. It decrypts this one slot's
  # private, straight into step's fd — never a variable, never a file; once per signed leaf. Its
  # stderr stays in the 0700 work dir: sops' text never reaches the terminal or a log.
  log "decrypting ${authority}@${slot}'s private to sign ${name} (the only decryption of this run for this leaf)"
  step certificate sign "$work/$i.csr" "$work/ca.crt" \
    <(sops --decrypt --extract "[\"authorities\"][\"${authority}\"][\"slots\"][\"${slot}\"][\"private\"]" "$keysYaml" 2>"$work/sops.err") \
    --template "$work/leaf.tpl" --not-after "$((days * 24))h" >"$work/$i.crt" 2>"$work/sign.err" || {
    # $! is the process substitution: its own exit, never its text.
    sopsRc=0
    wait "$!" || sopsRc=$?
    [ "$sopsRc" -eq 0 ] || die "sops decrypt of ${authority}@${slot} failed (exit ${sopsRc}) — is the operator's sops age key available on this operator seat?"
    die "step certificate sign failed: $(tail -1 "$work/sign.err")"
  }
  step certificate verify "$work/$i.crt" --roots "$work/ca.crt" --host "$name" >/dev/null ||
    die "the signed leaf does not chain to ${authority}@${slot} for ${name}"
  [[ "$(pubOf x509 "$work/$i.crt")" == "$(pubOf req "$work/$i.csr")" ]] || die "the signed leaf does not carry the CSR's key"
  leafFp="$(openssl x509 -noout -fingerprint -sha256 -in "$work/$i.crt" | sed -e 's/.*=//')"
  log "signed leaf sha256 ${leafFp}"

  # --- The record: the operator seat's ledger -------------------------------------------------
  {
    printf '# sha256 %s\n# signed %s by %s@%s for %s\n' "$leafFp" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$authority" "$slot" "$name"
    cat "$work/$i.crt"
  } >"$ledger/${leafFp//:/}.crt"
  log "recorded in ${ledger}/${leafFp//:/}.crt"

  # --- Install into the dataset on the guest; the container takes it by itself ---------------
  remoteVia="$via"
  remoteDir="$(sshq "$via" 'd="/run/user/$(id -u)"; [ -d "$d" ] || exit 3; umask 077; mktemp -d "$d/attic-leaf.XXXXXX"')" ||
    die "cannot open a private tmpfs directory on ${via} (/run/user/<uid> is required)"
  log "sending the leaf (public) to ${via}…"
  sshq "$via" "cat > '$remoteDir/leaf.crt'" <"$work/$i.crt" || die "cannot send the leaf to ${via}"
  sshq "${tty[@]}" "$via" "$rsudo install -m 0644 '$remoteDir/leaf.crt' '$hostTls/cert.pem'" ||
    die "cannot install the leaf as ${hostTls}/cert.pem on ${via}"
  if sshq "$via" "rm -rf '$remoteDir'"; then remoteDir=""; else log "WARN: could not remove $remoteDir on $via yet — the exit trap retries"; fi

  # --- Verify: the cache serves exactly this leaf, chaining to the root, by name ----------------
  # The container's attic-tls-leaf.path restarts attic-tls-key and nginx on the new file.
  for _ in $(seq 1 30); do
    [[ "$(served "$name")" == "$leafFp" ]] && break
    sleep 1
  done
  verdict="$(chains "$name")"
  now="$(served "$name")"
  if [[ $now == "$leafFp" && $verdict == "Verification: OK" ]]; then
    log "ok   ${name}: serves the signed leaf, chains to ${caFp}, name verified"
  else
    die "${name} serves ${now:-nothing}, not the signed leaf ${leafFp} (${verdict:-no verification}) — check \`journalctl -u attic-tls-key\` in its container"
  fi
done

log "done. Every cache serves a leaf of ${authority}@${slot} naming itself alone."
