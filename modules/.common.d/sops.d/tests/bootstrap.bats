#!/usr/bin/env bats
# The age bootstrap, rendered with test paths: a missing identity is a loud fault and is never generated;
# a present one gets root:root 0400 on a NixOS guest. age-keygen and chown are stubbed first on PATH and
# log every call, so "never generated" is a fact, not an absence of output.

bats_require_minimum_version 1.5.0

setup() {
  t="$BATS_TEST_TMPDIR"
  mkdir -p "$t/bin" "$t/share" "$t/var"
  : >"$t/trampoline.sh"
  cat >"$t/bin/age-keygen" <<EOF
#!/usr/bin/env bash
echo "age-keygen \$*" >>"$t/calls"
[ "\$1" = -y ] && echo age1testrecipient
EOF
  cat >"$t/bin/chown" <<EOF
#!/usr/bin/env bash
echo "chown \$*" >>"$t/calls"
EOF
  chmod +x "$t/bin/age-keygen" "$t/bin/chown"
  : >"$t/calls"
  key="$t/var/lib/sops-nix/guest.age"
  render 0 1
}

render() { # <import-from-host 0|1> <enforce-root-mode 0|1>
  sed -e "s#@nixBashTrampoline@#$t/trampoline.sh#" -e "s#@keyFile@#$key#" \
    -e "s#@publicKeyFile@#$t/var/etc/keys.pub#" -e 's#@exportPublicKeyOnActivation@#1#' \
    -e "s#@nixosImportFromHost@#$1#" -e "s#@enforceRootKeyMode@#$2#" \
    -e "s#@nixosHostKeyImportCandidates@#$t/share/keys.txt#" \
    "$BATS_TEST_DIRNAME/../bootstrap.sh" >"$t/bootstrap"
}

run_bootstrap() { PATH="$t/bin:$PATH" run bash "$t/bootstrap"; }
mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }

@test "a missing identity is a loud fault, and nothing is generated" {
  run_bootstrap
  [ "$status" -eq 1 ]
  [[ "$output" == *"no age identity at $key"* ]]
  [[ "$output" == *"never generated here"* ]]
  [[ "$output" == *"ndh-identity-reload"* ]]
  [ ! -e "$key" ]
  run ! grep -q 'age-keygen' "$t/calls"
}

@test "a present identity is set to root:root 0400 on a NixOS guest, whatever its mode was" {
  mkdir -p "$(dirname "$key")"
  printf 'AGE-SECRET-KEY-1TEST\n' >"$key"
  chmod 0644 "$key"
  run_bootstrap
  [ "$status" -eq 0 ]
  [ "$(mode "$key")" = 400 ]
  grep -q "chown root:root $key" "$t/calls"
  [ "$(cat "$t/var/etc/keys.pub")" = age1testrecipient ]
  run ! grep -q 'age-keygen -o' "$t/calls"
}

@test "on darwin the keyFile's mode and owner are left alone" {
  render 0 0
  mkdir -p "$(dirname "$key")"
  printf 'AGE-SECRET-KEY-1TEST\n' >"$key"
  chmod 0600 "$key"
  run_bootstrap
  [ "$status" -eq 0 ]
  [ "$(mode "$key")" = 600 ]
  run ! grep -q 'chown' "$t/calls"
}

@test "a host-provided key is imported at 0400 when the guest imports its host's key" {
  render 1 1
  printf 'AGE-SECRET-KEY-1HOST\n' >"$t/share/keys.txt"
  run_bootstrap
  [ "$status" -eq 0 ]
  [ "$(cat "$key")" = AGE-SECRET-KEY-1HOST ]
  [ "$(mode "$key")" = 400 ]
  run ! grep -q 'age-keygen -o' "$t/calls"
}

@test "without a host-provided key, the import falls through to the loud fault" {
  render 1 1
  run_bootstrap
  [ "$status" -eq 1 ]
  [[ "$output" == *"no age identity"* ]]
  [ ! -e "$key" ]
}

@test "an image build skips the check" {
  NIXOS_INSTALL_BOOTLOADER=1 PATH="$t/bin:$PATH" run bash "$t/bootstrap"
  [ "$status" -eq 0 ]
  [ ! -e "$key" ]
}
