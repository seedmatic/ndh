#!/usr/bin/env bats
# corp-egress-anchor against a stand-in pfctl, on placeholder addresses: the v6 rules built from the secret, the
# router kept, the rest of fe80::/10 left open, and every way a bad secret must fail closed, loading nothing.

bats_require_minimum_version 1.5.0

setup() {
  t="$BATS_TEST_TMPDIR"
  mkdir -p "$t/bin" "$t/anchors"
  # The stand-in keeps the loaded anchor in a file, as pf keeps it in the kernel.
  cat >"$t/bin/pfctl" <<EOF
#!$BASH
[ -e "$t/refuse" ] && [ "\$3" = -n ] && exit 1
case "\$3 \$4" in
  "-n -f") exit 0 ;;
  "-f "*) cp "\$4" "$t/loaded" ;;
  "-s rules") cat "$t/loaded" 2>/dev/null ;;
esac
EOF
  chmod +x "$t/bin/pfctl"
  printf '%s\n' "pass out quick inet proto tcp to 192.0.2.65 port 22 user operator keep state" \
    "block out quick log inet to 192.0.2.65" "block out quick log inet to 198.51.100.2" >"$t/v4"
  printf '%s\n' "home_prefix 2001:db8:1:2::/64" "router 2001:db8:1:2::1" \
    "link_local fe80::aaaa:bbbb fe80::cccc:dddd" >"$t/secret"
}

load_anchor() { bash -euo pipefail "$BATS_TEST_DIRNAME/../anchor.sh" "$t/v4" "$t/secret" "$t/anchors/a" "$t/bin/pfctl" test.anchor; }

@test "the anchor holds the v4 rules, the router kept, the /64 and each fe80 blocked, and nothing more" {
  run load_anchor
  [ "$status" -eq 0 ]
  diff - "$t/loaded" <<'EOF'
pass out quick inet proto tcp to 192.0.2.65 port 22 user operator keep state
block out quick log inet to 192.0.2.65
block out quick log inet to 198.51.100.2
pass out quick inet6 to 2001:db8:1:2::1
block out quick log inet6 to 2001:db8:1:2::/64
block out quick log inet6 to fe80::aaaa:bbbb
block out quick log inet6 to fe80::cccc:dddd
EOF
}

@test "link-local is never blocked whole: Continuity keeps fe80::/10" {
  run load_anchor
  [ "$status" -eq 0 ]
  ! grep -q 'fe80::/10' "$t/loaded"
}

@test "the anchor file is root-only (0600)" {
  run load_anchor
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$t/anchors/a" 2>/dev/null || stat -f %Lp "$t/anchors/a")" = 600 ]
}

@test "a missing secret loads nothing" {
  rm "$t/secret"
  run load_anchor
  [ "$status" -ne 0 ]
  [ ! -e "$t/loaded" ]
  [[ $output == *"the v6 secret is missing or empty: nothing loaded"* ]]
}

@test "an empty secret loads nothing" {
  : >"$t/secret"
  run load_anchor
  [ "$status" -ne 0 ]
  [ ! -e "$t/loaded" ]
}

@test "a symlinked secret loads nothing" {
  mv "$t/secret" "$t/real" && ln -s "$t/real" "$t/secret"
  run load_anchor
  [ "$status" -ne 0 ]
  [ ! -e "$t/loaded" ]
}

@test "a prefix that is not a /64 loads nothing" {
  sed -i.bak 's|::/64|::/48|' "$t/secret"
  run load_anchor
  [ "$status" -ne 0 ]
  [[ $output == *"home_prefix is not a /64"* ]]
}

@test "a router outside the /64 loads nothing" {
  sed -i.bak 's|^router .*|router 2001:db8:9:9::1|' "$t/secret"
  run load_anchor
  [ "$status" -ne 0 ]
  [[ $output == *"router is not an address inside home_prefix"* ]]
}

@test "no link-local address loads nothing" {
  sed -i.bak '/^link_local/d' "$t/secret"
  run load_anchor
  [ "$status" -ne 0 ]
  [[ $output == *"no link_local address"* ]]
}

@test "a link-local entry outside fe80 loads nothing" {
  sed -i.bak 's|fe80::cccc:dddd|2001:db8:1:2::9|' "$t/secret"
  run load_anchor
  [ "$status" -ne 0 ]
  [[ $output == *"not an fe80 address"* ]]
}

@test "rules pfctl refuses are not loaded, and the previous anchor file stays" {
  echo previous >"$t/anchors/a"
  touch "$t/refuse"
  run load_anchor
  [ "$status" -ne 0 ]
  [ "$(cat "$t/anchors/a")" = previous ]
  [ ! -e "$t/loaded" ]
}

@test "missing v4 rules load nothing" {
  : >"$t/v4"
  run load_anchor
  [ "$status" -ne 0 ]
  [[ $output == *"the v4 rules"* ]]
}
