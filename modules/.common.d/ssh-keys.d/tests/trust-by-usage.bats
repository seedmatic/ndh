#!/usr/bin/env bats
#
# An authority is trusted for ssh by its declared ROLE, never by its file name.
#
# Every `*-ca.pub` the extractor writes is trusted twice: sshd's TrustedUserCAKeys (ssh-trusted-user-ca, darwin and
# NixOS) takes it as a USER certificate authority, and the operator's KnownHostsCommand vouches it as a HOST one. So
# the split expression writes a `-ca.pub` for an authority whose `usage` holds `ssh-authority` only. This suite runs
# the chain as built — the real split expression, then the two real aggregators over what it wrote — on a registry
# that also holds a TLS authority, and checks both outputs; mutants of the expression show it bites.

load helper

SPLIT_EXP="${BATS_TEST_DIRNAME}/../../../home-manager/ssh-key.d/ssh-extract-keys.split-exp.yq"
TRUSTED_USER_CA="${BATS_TEST_DIRNAME}/../ssh-trusted-user-ca.sh"
NAMES="alpha,alpha.fabric.test"

setup() {
  [ -r "$SPLIT_EXP" ] && [ -r "$TRUSTED_USER_CA" ] && [ -r "${KNOWN_HOSTS_COMMAND:?}" ]
  tmp="$BATS_TEST_TMPDIR"
  ssh-keygen -q -t ed25519 -N '' -C ssh-ca -f "$tmp/ssh-ca"
  ssh-keygen -q -t ecdsa -b 256 -N '' -C tls-ca -f "$tmp/tls-ca"
  ssh-keygen -q -t ed25519 -N '' -C bare-ca -f "$tmp/bare-ca"
  SSH_PUB="$(cut -d' ' -f2 "$tmp/ssh-ca.pub")"
  TLS_PUB="$(cut -d' ' -f2 "$tmp/tls-ca.pub")"
  BARE_PUB="$(cut -d' ' -f2 "$tmp/bare-ca.pub")"
  cat >"$tmp/keys.yaml" <<YAML
authorities:
  fabric:
    type: ssh-ed25519
    comment: cert-authority@fabric
    usage: [ssh-authority]
    slots:
      26-10-10: { public: ${SSH_PUB} }
  fabric-tls:
    type: ecdsa-sha2-nistp256
    comment: cert-authority@fabric-tls
    usage: [tls-authority]
    slots:
      26-10-10: { public: ${TLS_PUB} }
  undeclared:
    type: ssh-ed25519
    comment: cert-authority@undeclared
    slots:
      26-10-10: { public: ${BARE_PUB} }
keys: {}
YAML
}

# The split expression's `-ca.pub` artefacts, written into <dir> the way the extractor writes a public: its content's
# first non-empty line.
extract_into() { # <expression> <dir>
  local out="$tmp/split" f rel content
  rm -rf "$out" && mkdir -p "$out" "$2"
  env TMPDIR="$out/" yq eval --from-file "$1" "$tmp/keys.yaml" -s '.yamlfile' >/dev/null
  for f in "$out"/*; do
    rel="$(yq -r '.rel_path' "$f")"
    [[ $rel == *-ca.pub ]] || continue
    content="$(yq -r '.content // ""' "$f")"
    [[ -n $content && $content != null ]] || continue
    printf '%s\n' "$content" | awk 'NF { print; exit }' >"$2/$rel"
  done
}

aggregate() { # <dir>: the TrustedUserCAKeys file ssh-trusted-user-ca builds from it
  (render_and_source "$TRUSTED_USER_CA" && main "$1")
  cat "$1/trusted-user-ca.pub"
}

known_hosts() { # <dir>: the @cert-authority lines the KnownHostsCommand emits for it
  printf 'source "%s"\nndh::logger:command:run() { shift; ndh::logger:command:invoke "$@"; return "$NDH_LOGGER_COMMAND_RC"; }\n' \
    "$NDH_LOGGER_SH" >"$tmp/trampoline.sh"
  sed -e "1s#^\#!/usr/bin/env bash#\#!$(command -v bash)#" \
    -e "s#@nixBashTrampoline@#$tmp/trampoline.sh#" -e "s#@caDir@#$1#" -e "s#@hostNames@#$NAMES#" \
    "$KNOWN_HOSTS_COMMAND" >"$tmp/known-hosts-command"
  chmod +x "$tmp/known-hosts-command"
  "$tmp/known-hosts-command"
}

@test "only the ssh-authority becomes a -ca.pub; the TLS one and an undeclared one do not" {
  extract_into "$SPLIT_EXP" "$tmp/keys.d"
  run ls "$tmp/keys.d"
  [ "$output" = fabric-ca.pub ]
}

@test "TrustedUserCAKeys trusts the ssh-authority, never the TLS authority nor one with no usage" {
  extract_into "$SPLIT_EXP" "$tmp/keys.d"
  run aggregate "$tmp/keys.d"
  [ "$status" -eq 0 ]
  [[ $output == *"$SSH_PUB"* ]]
  [[ $output != *"$TLS_PUB"* ]]
  [[ $output != *"$BARE_PUB"* ]]
  [ "$(stat -c %a "$tmp/keys.d/trusted-user-ca.pub")" = 644 ]
}

@test "the KnownHostsCommand vouches the ssh-authority as a host CA, never the TLS authority nor one with no usage" {
  extract_into "$SPLIT_EXP" "$tmp/keys.d"
  run known_hosts "$tmp/keys.d"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ $output == "@cert-authority $NAMES ssh-ed25519 $SSH_PUB" ]]
}

@test "mutant: a split expression that trusts by name puts the TLS authority in BOTH outputs" {
  sed 's/ | map(select((.value.usage \/\/ \[\]) | any_c(. == "ssh-authority")))//' "$SPLIT_EXP" >"$tmp/by-name.yq"
  ! grep -q 'ssh-authority' "$tmp/by-name.yq"
  extract_into "$tmp/by-name.yq" "$tmp/keys.d"
  [[ "$(aggregate "$tmp/keys.d")" == *"$TLS_PUB"* ]]
  [[ "$(known_hosts "$tmp/keys.d")" == *"ecdsa-sha2-nistp256 $TLS_PUB"* ]]
}

@test "mutant: a split expression that trusts any declared usage still puts the TLS authority in both" {
  sed 's/any_c(. == "ssh-authority")/length > 0/' "$SPLIT_EXP" >"$tmp/any-usage.yq"
  grep -q 'length > 0' "$tmp/any-usage.yq"
  extract_into "$tmp/any-usage.yq" "$tmp/keys.d"
  [[ "$(aggregate "$tmp/keys.d")" == *"$TLS_PUB"* ]]
  [[ "$(known_hosts "$tmp/keys.d")" == *"$TLS_PUB"* ]]
}

@test "a TLS -ca.pub left by an earlier activation is gone after the extractor's next run" {
  : "the machines' directories hold one today: the fix takes effect at the switch only if the extractor wipes it"
  local extractor="${BATS_TEST_DIRNAME}/../../../home-manager/ssh-key.d/ssh-extract-keys.sh"
  sed -e "s|@nixBashTrampoline@|$(ndh_trampoline)|g" -e "s|@loggerTag@|test.ssh-keys|g" \
    -e "s|@splitExpFile@|$SPLIT_EXP|g" "$extractor" >"$tmp/ssh-extract-keys"
  mkdir -p "$tmp/keys.d"
  printf 'ecdsa-sha2-nistp256 %s stale\n' "$TLS_PUB" >"$tmp/keys.d/fabric-tls-ca.pub"
  run bash "$tmp/ssh-extract-keys" "$tmp/keys.yaml" "$tmp/keys.d" "$(id -un)"
  [ "$status" -eq 0 ]
  [ ! -e "$tmp/keys.d/fabric-tls-ca.pub" ]
  [ -s "$tmp/keys.d/fabric-ca.pub" ]
  [[ "$(aggregate "$tmp/keys.d")" != *"$TLS_PUB"* ]]
}
