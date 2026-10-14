#!/usr/bin/env bats
# restart-on-secret-change against fake sops-nix generations, with launchctl and id stubbed first on
# PATH: what is kickstarted, what is not, and that no secret value ever reaches the output.

bats_require_minimum_version 1.5.0

setup() {
  t="$BATS_TEST_TMPDIR"
  mkdir -p "$t/bin" "$t/secrets.d/3" "$t/secrets.d/4"
  ln -s "$t/secrets.d/4" "$t/secrets"
  cat >"$t/bin/launchctl" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$t/kickstarts"
EOF
  cat >"$t/bin/id" <<'EOF'
#!/usr/bin/env bash
[ "$1" = -u ] && [ "$2" = alice ] && echo 501
EOF
  chmod +x "$t/bin/launchctl" "$t/bin/id"
  printf 'old-token-value' >"$t/secrets.d/3/token"
  printf 'new-token-value' >"$t/secrets.d/4/token"
  printf 'same-key-value' >"$t/secrets.d/3/key"
  printf 'same-key-value' >"$t/secrets.d/4/key"
  : >"$t/kickstarts"
}

restart() { PATH="$t/bin:$PATH" bash -euo pipefail "$BATS_TEST_DIRNAME/../restart-on-secret-change.sh" "$t/secrets" "$t/manifest"; }
manifest() { printf '%s\n' "$@" >"$t/manifest"; }

@test "a changed secret kickstarts its service, and its value is never printed" {
  manifest $'system\torg.example.daemon\tthe token changed\ttoken'
  run restart
  [ "$status" -eq 0 ]
  [ "$(cat "$t/kickstarts")" = "kickstart -k system/org.example.daemon" ]
  [[ "$output" == *"org.example.daemon: the token changed; restarting it"* ]]
  [[ "$output" != *"token-value"* ]]
}

@test "an unchanged secret restarts nothing" {
  manifest $'system\torg.example.daemon\tthe key changed\tkey'
  run restart
  [ "$status" -eq 0 ]
  [ ! -s "$t/kickstarts" ]
  [ -z "$output" ]
}

@test "a secret the previous generation lacks counts as changed" {
  printf 'v' >"$t/secrets.d/4/renamed"
  manifest $'system\torg.example.daemon\ta new key\trenamed'
  run restart
  [ "$status" -eq 0 ]
  [ "$(cat "$t/kickstarts")" = "kickstart -k system/org.example.daemon" ]
}

@test "no previous generation at all (a reboot) counts as changed" {
  rm -rf "$t/secrets.d/3"
  manifest $'system\torg.example.daemon\tthe key changed\tkey'
  run restart
  [ "$status" -eq 0 ]
  [ "$(cat "$t/kickstarts")" = "kickstart -k system/org.example.daemon" ]
}

@test "the previous generation is the highest one below the current, whatever else is there" {
  mkdir -p "$t/secrets.d/1" "$t/secrets.d/9" "$t/secrets.d/tmp"
  printf 'new-token-value' >"$t/secrets.d/3/token"
  printf 'old-token-value' >"$t/secrets.d/1/token"
  manifest $'system\torg.example.daemon\tthe token changed\ttoken'
  run restart
  [ "$status" -eq 0 ]
  [ ! -s "$t/kickstarts" ]
}

@test "a user agent is kickstarted in its user's gui domain" {
  manifest $'gui:alice\tio.example.agent\tthe token changed\ttoken'
  run restart
  [ "$status" -eq 0 ]
  [ "$(cat "$t/kickstarts")" = "kickstart -k gui/501/io.example.agent" ]
}

@test "a secret absent from the new generation fails the run and leaves that service alone, not the others" {
  manifest $'system\torg.example.broken\tx\tmissing token' $'system\torg.example.daemon\tthe token changed\ttoken'
  run restart
  [ "$status" -eq 1 ]
  [[ "$output" == *"org.example.broken: missing is absent from the new generation; not restarted"* ]]
  [ "$(cat "$t/kickstarts")" = "kickstart -k system/org.example.daemon" ]
}

@test "one changed secret among several is enough" {
  manifest $'system\torg.example.daemon\ta key changed\tkey token'
  run restart
  [ "$status" -eq 0 ]
  [ "$(cat "$t/kickstarts")" = "kickstart -k system/org.example.daemon" ]
}
