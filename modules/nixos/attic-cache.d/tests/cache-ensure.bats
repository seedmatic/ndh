#!/usr/bin/env bats
#
# attic-cache-ensure: the cache is created with a key generated here and named as the catalog accepts it,
# a cache found under another key name is rekeyed, one already right is left alone, a public one refused;
# neither the token nor the secret key is an argument or printed. atticd-atticadm, attic, nix and curl
# are stubbed: the cache's state is a file, each call is logged with its arguments.

setup() {
  t="$BATS_TEST_TMPDIR"
  mkdir -p "$t/bin" "$t/tmp"
  state="$t/cache" # absent: no cache; else its key name, then "public" if public
  cat >"$t/bin/atticd-atticadm" <<EOF
#!$BASH
printf '%s\n' "atticadm \$*" >>"$t/calls"
printf 'TOKENVALUE'
EOF
  cat >"$t/bin/attic" <<EOF
#!$BASH
printf '%s\n' "attic \$*" >>"$t/calls"
case "\$1 \$2" in
  "cache info")
    [ -e "$state" ] || exit 1
    read -r name visibility <"$state"
    { echo "Public: \$([ "\$visibility" = public ] && echo true || echo false)"; echo "               Public Key: \$name:PUBLICBASE64="; } >&2 ;;
esac
EOF
  cat >"$t/bin/nix" <<EOF
#!$BASH
printf '%s\n' "nix \$*" >>"$t/calls"
while [ \$# -gt 0 ]; do case "\$1" in --key-name) name="\$2"; shift 2 ;; *) shift ;; esac; done
printf '%s:SECRETVALUE==\n' "\$name"
EOF
  # curl: records its arguments, and the request it was handed (by @file) as what the server stored.
  cat >"$t/bin/curl" <<EOF
#!$BASH
printf '%s\n' "curl \$*" >>"$t/calls"
for a in "\$@"; do case "\$a" in @*.json) req="\${a#@}" ;; @*) auth="\${a#@}" ;; esac; done
cp "\$auth" "$t/auth-seen"
key=\$(jq -r '.keypair.Keypair' "\$req")
public=\$(jq -r '.is_public // false' "\$req")
echo "\${key%%:*} \$([ "\$public" = true ] && echo public)" >"$state"
EOF
  chmod +x "$t/bin/"*
  script="${BATS_TEST_DIRNAME}/../cache-ensure.sh"
}

run_ensure() {
  TMPDIR="$t/tmp" PATH="$t/bin:$PATH" run --separate-stderr bash -euo pipefail "$script" \
    seedmatic seedmatic-m1-attic-1 "6 hours" http://127.0.0.1:8080 cache.nixos.org-1 flox-cache-public-1
}

no_secret_out() {
  ! grep -q -e TOKENVALUE -e SECRETVALUE "$t/calls" || false
  [[ $output$stderr != *TOKENVALUE* && $output$stderr != *SECRETVALUE* ]]
  [ -z "$(ls -A "$t/tmp")" ]
}

@test "a new cache is created with a key generated here, named as the catalog accepts it, private" {
  run_ensure
  [ "$status" -eq 0 ]
  grep -q '^nix .*key generate-secret --key-name seedmatic-m1-attic-1$' "$t/calls"
  grep -q '^curl .*-X POST .*http://127.0.0.1:8080/_api/v1/cache-config/seedmatic$' "$t/calls"
  [ "$(cat "$state")" = "seedmatic-m1-attic-1 " ]
  [[ $output == *"Public Key: seedmatic-m1-attic-1:"* ]]
  grep -qx 'Authorization: Bearer TOKENVALUE' "$t/auth-seen"
  no_secret_out
}

@test "a cache found under another key name gets a new key, named right" {
  echo "seedmatic" >"$state"
  run_ensure
  [ "$status" -eq 0 ]
  [[ $stderr == *"key is named seedmatic, not seedmatic-m1-attic-1"* ]]
  grep -q '^curl .*-X PATCH ' "$t/calls"
  [[ $output == *"Public Key: seedmatic-m1-attic-1:"* ]]
  no_secret_out
}

@test "a cache already under the right key name is not rekeyed" {
  echo "seedmatic-m1-attic-1" >"$state"
  run_ensure
  [ "$status" -eq 0 ]
  ! grep -q '^curl ' "$t/calls" || false
  ! grep -q '^nix ' "$t/calls" || false
  grep -q -- '--retention-period 6 hours --upstream-cache-key-name cache.nixos.org-1 --upstream-cache-key-name flox-cache-public-1' "$t/calls"
}

@test "a public cache is refused" {
  echo "seedmatic-m1-attic-1 public" >"$state"
  run_ensure
  [ "$status" -eq 1 ]
  [[ $stderr == *"is public — refusing"* ]]
}
