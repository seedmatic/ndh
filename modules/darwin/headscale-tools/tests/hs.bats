#!/usr/bin/env bats
# hs, the REAL script with hs-lib inlined as the build does it, traced (bash -x): no preauth key and no API key
# reaches the trace, nor any command's argv. headscale and sops are stubs that record their argv (what ps would
# show); yq is real. The keys are recognizable fakes: FAKEKEY-… on the server, FAKEAPI-… for the API key.

refute() {
  local rc=0
  "$@" || rc=$?
  case $rc in
    1) return 0 ;;
    0) echo "refuted, but it held: $*" >&2; return 1 ;;
    *) echo "refute got no answer (rc=$rc): $*" >&2; return 1 ;;
  esac
}

setup() {
  T=$BATS_TEST_TMPDIR
  mkdir -p "$T/bin" "$T/repo"
  # The server: one key for darwin with its expected tags, one stale-tagged for nixos.
  cat >"$T/server.json" <<'EOF'
[{"id": "1", "key": "FAKEKEY-darwin-0123456789abcdef", "aclTags": ["tag:console", "tag:darwin"]},
 {"id": "2", "key": "FAKEKEY-nixos-0123456789abcdef", "aclTags": ["tag:service"]}]
EOF
  cat >"$T/bin/headscale" <<EOF
#!$BASH
printf '%s\n' "\$*" >>"$T/argv"
case "\$*" in
  *"preauthkeys list"*) cat "$T/server.json" ;;
  *"preauthkeys create"*) echo '{"key": "FAKEKEY-minted-0123456789abcdef"}' ;;
  *"users list"*) echo '[{"id": "7", "name": "operator"}]' ;;
  *) echo "stub headscale: \$*" >&2 ;;
esac
EOF
  # sops: "decrypt" and "encrypt" copy the plain YAML (the encryption is not under test, the channels are).
  cat >"$T/bin/sops" <<EOF
#!$BASH
printf '%s\n' "\$*" >>"$T/argv"
for f; do :; done
cat "\$f"
EOF
  chmod +x "$T/bin/headscale" "$T/bin/sops"
  printf 'FAKEAPI-0123456789abcdef\n' >"$T/api.key"
  cat >"$T/repo/.secrets" <<'EOF'
tailnet:
  headscale:
    auth:
      darwin: FAKEKEY-darwin-0123456789abcdef
      nixos: FAKEKEY-nixos-0123456789abcdef
EOF
  # The script as the build renders it: hs-lib inlined at @HS_LIB_INLINE@, the logger at @LOGGER_SH@.
  local d=$BATS_TEST_DIRNAME/..
  {
    printf '#!%s\nset -euo pipefail\n' "$BASH"
    awk -v lib="$d/hs-lib.sh" '/@HS_LIB_INLINE@/ { while ((getline l < lib) > 0) print l; next } { print }' "$d/hs.sh"
  } | sed -e "s#@LOGGER_SH@#${NDH_LOGGER_SH:?the logger}#" -e "s#@API_KEY_FILE@#$T/api.key#" \
    -e 's#@HEADSCALE_HOSTNAME@#hs.test#' -e 's#@EXPECTED_USER@#operator#' -e 's#@MINT_EXPIRATION@#10y#' >"$T/hs"
  # No local config: hs goes through the API key, the path that loads it.
  export PATH="$T/bin:$PATH" NDH_SECRETS_FILE="$T/repo/.secrets" HOME="$T"
}

no_key_anywhere() {
  refute grep -qE 'FAKEKEY|FAKEAPI' "$T/trace"
  refute grep -qE 'FAKEKEY|FAKEAPI' "$T/argv"
  [[ $output != *FAKEKEY* && $output != *FAKEAPI* ]]
}

traced() { # <hs args>
  status=0
  bash -x "$T/hs" "$@" >"$T/out" 2>"$T/trace" || status=$?
  output=$(cat "$T/out" "$T/trace" | grep -v '^+')
}

@test "check, traced: the stale tags are reported, and no key reaches the trace or an argv" {
  traced check
  [ "$status" -eq 0 ]
  [[ $output == *"auth.nixos server tags [tag:service] disagree with expected [tag:headless,tag:nixos]"* ]]
  [[ $output != *"auth.darwin"* ]]
  grep -qF "secret window: the preauth keys of the server are listed" "$T/trace"
  no_key_anywhere
}

@test "check: an empty slot is skipped silently, a key the server does not know is stale" {
  yq -i '.tailnet.headscale.auth.darwin = "" | .tailnet.headscale.auth.incus = "FAKEKEY-gone-0123456789abcdef"' "$T/repo/.secrets"
  traced check
  [ "$status" -eq 0 ]
  [[ $output != *"auth.darwin"* ]]
  [[ $output == *"auth.incus in .secrets has no matching preauth key on server (stale"* ]]
  no_key_anywhere
}

@test "mint, traced: the new key lands in its slot, and no key reaches the trace or an argv" {
  traced mint --force darwin
  [ "$status" -eq 0 ]
  [[ $output == *"auth.darwin: minted and written"* ]]
  [ "$(yq -r '.tailnet.headscale.auth.darwin' "$T/repo/.secrets")" = FAKEKEY-minted-0123456789abcdef ]
  no_key_anywhere
}

@test "mint without --force leaves a live slot alone" {
  traced mint darwin
  [ "$status" -eq 0 ]
  [[ $output == *"auth.darwin: already live with expected tags, skipping"* ]]
  [ "$(yq -r '.tailnet.headscale.auth.darwin' "$T/repo/.secrets")" = FAKEKEY-darwin-0123456789abcdef ]
  no_key_anywhere
}
