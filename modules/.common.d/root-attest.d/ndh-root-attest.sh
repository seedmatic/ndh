# ndh-root-attest — the seedmatic root's attestation of an authority (roles × keys ⑧, docs/root-ceremony.adoc).
#
#   ndh-root-attest statement --name N --usage U --key "<type> <base64>" --not-after YYYY-MM-DD
#       prints the canonical statement the root signs, and nothing else
#   ndh-root-attest verify --root "<type> <base64>" --statement FILE --signature FILE
#                          --name N --usage U --key "<type> <base64>" [--today YYYY-MM-DD]
#       exit 0 only if the root signed exactly that statement (sshsig, namespace seedmatic-attest), the statement
#       names that authority, that usage and that key, and its not-after has not passed
#
# The root signs a STATEMENT, not a bare public (🛡️): a bare public would stay valid forever and could be replayed
# for another usage. The statement is rebuilt here from the expected fields and compared byte for byte, so nothing
# in it is parsed beyond its not-after.

readonly namespace="seedmatic-attest"
readonly principal="seedmatic-root"
# The SSH authorities only: the TLS intermediate is attested by the root's X.509 signature over its certificate.
usages=(ssh-host ssh-user)

die() {
  printf '[ndh-root-attest] ERROR: %s\n' "$*" >&2
  exit 1
}
usage() { die "$* (usage: ndh-root-attest statement|verify --name N --usage U --key K …)"; }

checkName() { [[ $1 =~ ^[a-z][a-z0-9-]*$ ]] || die "an authority name is lower-case letters, digits and dashes: ${1@Q}"; }
checkUsage() {
  local u
  for u in "${usages[@]}"; do [[ $1 == "$u" ]] && return 0; done
  die "a usage is one of ${usages[*]}, not ${1@Q}"
}
checkKey() { # <public line> <what>
  [[ $1 =~ ^(ssh-ed25519|ecdsa-sha2-nistp(256|384|521))\ [A-Za-z0-9+/]+=*$ ]] ||
    die "$2 is not ONE ssh public, <type> <base64>"
}
checkDate() { # <YYYY-MM-DD> <what>
  [[ $1 =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && [[ "$(date -u -d "$1" +%F 2>/dev/null)" == "$1" ]] ||
    die "$2 is not a date, YYYY-MM-DD: ${1@Q}"
}

render() { # <name> <usage> <key> <not-after>
  printf 'seedmatic-attest v1\nname %s\nusage %s\nkey %s\nnot-after %s\n' "$1" "$2" "$3" "$4"
}

(($# >= 1)) || usage "a command: statement or verify"
command="$1"
shift
declare -A arg=()
while (($#)); do
  case "$1" in
    --name | --usage | --key | --not-after | --root | --statement | --signature | --today)
      (($# >= 2)) || usage "$1 needs a value"
      arg[${1#--}]="$2"
      shift 2
      ;;
    *) usage "unknown argument ${1@Q}" ;;
  esac
done

for field in name usage key; do [[ -v "arg[$field]" ]] || usage "--${field} is required"; done
checkName "${arg[name]}"
checkUsage "${arg[usage]}"
checkKey "${arg[key]}" "--key"

case "$command" in
  statement)
    [[ -v "arg[not-after]" ]] || usage "--not-after is required"
    checkDate "${arg[not-after]}" "--not-after"
    render "${arg[name]}" "${arg[usage]}" "${arg[key]}" "${arg[not-after]}"
    ;;
  verify)
    for field in root statement signature; do [[ -v "arg[$field]" ]] || usage "--${field} is required"; done
    checkKey "${arg[root]}" "--root"
    # The root is P-384 (decided 2026-10-18): importable into any hardware token later.
    [[ ${arg[root]} == ecdsa-sha2-nistp384\ * ]] || die "the root is a P-384 key (ecdsa-sha2-nistp384)"
    [[ -f ${arg[statement]} && -f ${arg[signature]} ]] || die "the statement or the signature is not a file"
    today="${arg[today]:-$(date -u +%F)}"
    checkDate "$today" "--today"
    notAfter="$(sed -n '5s/^not-after //p' "${arg[statement]}")"
    checkDate "$notAfter" "the statement's not-after"
    cmp -s "${arg[statement]}" <(render "${arg[name]}" "${arg[usage]}" "${arg[key]}" "$notAfter") ||
      die "the statement does not attest ${arg[name]} for ${arg[usage]} with that key"
    [[ ! $notAfter < $today ]] || die "the attestation of ${arg[name]} expired on ${notAfter}"
    work="$(mktemp -d)"
    trap 'rm -rf "$work"' EXIT
    printf '%s namespaces="%s" %s\n' "$principal" "$namespace" "${arg[root]}" >"$work/allowed_signers"
    ssh-keygen -Y verify -f "$work/allowed_signers" -I "$principal" -n "$namespace" \
      -s "${arg[signature]}" <"${arg[statement]}" >/dev/null 2>&1 ||
      die "the signature is not the root's over that statement"
    printf 'ok %s %s until %s\n' "${arg[name]}" "${arg[usage]}" "$notAfter"
    ;;
  *) usage "unknown command ${command@Q}" ;;
esac
