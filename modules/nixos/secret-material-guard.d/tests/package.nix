# The secret-material guard, proven by canaries: a store layer that would pack a private key, or an
# age secret, is NOT built, the refusal names the path and never the value, a reviewed public test key
# is packed, and --root leaves its pruned subtrees out. The canaries are generated at build time:
# written into this file, they would be the secret material the repository's own pre-commit refuses.
{ pkgs, nixBashTrampoline }:
let
  guard = import ../../secret-material-guard.nix { inherit pkgs; };
  layer =
    path:
    import ../../erofs-store-image.nix {
      inherit pkgs nixBashTrampoline;
      closureInfo = pkgs.closureInfo { rootPaths = [ path ]; };
      name = "secret-material-guard-canary-layer";
    };
  canaryKey = pkgs.runCommand "secret-material-guard-canary-key" { } ''
    mkdir "$out"
    {
      echo '-----BEGIN OPENSSH PRIVATE '"KEY-----"
      head -c 48 /dev/urandom | base64 -w0
      echo
      echo '-----END OPENSSH PRIVATE '"KEY-----"
    } > "$out/id_canary"
  '';
  canaryAge = pkgs.runCommand "secret-material-guard-canary-age" { } ''
    mkdir "$out"
    printf 'AGE-SECRET-'"KEY-1%s\n" "$(head -c 400 /dev/urandom | base64 -w0 | tr -dc 'A-Z0-9' | head -c 58)" > "$out/age.txt"
  '';
  # A public example key nixpkgs ships, whose content is on the allow-list.
  publicKey = pkgs.runCommand "secret-material-guard-public-key" { } ''
    mkdir "$out"
    cp ${pkgs.path}/nixos/modules/profiles/keys/ssh_host_ed25519_key "$out/"
  '';
  refusedKey = pkgs.testers.testBuildFailure (layer canaryKey);
  refusedAge = pkgs.testers.testBuildFailure (layer canaryAge);
in
pkgs.runCommand "secret-material-guard-tests" { } ''
  set -euo pipefail
  log=${refusedKey}/testBuildFailure.log
  grep -q "secret-material-guard: REFUSED ${canaryKey}/id_canary" "$log"
  # The value never reaches the log: neither the key's body line nor the age key.
  ! grep -qF "$(sed -n 2p ${canaryKey}/id_canary)" "$log"
  grep -q "secret-material-guard: REFUSED ${canaryAge}/age.txt" ${refusedAge}/testBuildFailure.log
  ! grep -qF "$(cat ${canaryAge}/age.txt)" ${refusedAge}/testBuildFailure.log

  # A reviewed public key is packed.
  test -s ${layer publicKey}

  # --root: a canary under a pruned subtree passes, one outside it is refused.
  mkdir -p root/keep root/skip
  cp ${canaryKey}/id_canary root/skip/
  bash ${guard} --root "$PWD/root" --prune "$PWD/root/skip"
  cp ${canaryKey}/id_canary root/keep/
  if bash ${guard} --root "$PWD/root" --prune "$PWD/root/skip" 2> err; then
    echo "the guard let a key outside the pruned subtree through" >&2
    exit 1
  fi
  grep -q "REFUSED $PWD/root/keep/id_canary" err

  # A subtree it cannot read refuses: never "nothing found" for what was not looked at.
  rm root/keep/id_canary
  mkdir -p root/locked
  cp ${canaryKey}/id_canary root/locked/
  chmod 000 root/locked
  if bash ${guard} --root "$PWD/root" --prune "$PWD/root/skip" 2> err; then
    echo "the guard passed a subtree it could not read" >&2
    exit 1
  fi
  grep -q "cannot be listed" err
  chmod 755 root/locked
  touch "$out"
''
