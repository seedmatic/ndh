# The ssh-keys bats suites as a flake check.
#
# The helper renders each script's @nixBashTrampoline@ placeholder; in the sandbox it
# cannot search /nix/store for the trampoline, so the check hands it over explicitly.
{ pkgs, trampoline }:
pkgs.runCommand "ssh-keys-bats"
  {
    nativeBuildInputs = with pkgs; [
      bats
      bash
      coreutils
      findutils
      gawk
      gnugrep
      gnused
      hostname
      jq
      openssh
      openssl
      step-cli
      yq-go
    ];
    NDH_TRAMPOLINE = trampoline;
  }
  # split-exp.bats reads the extractor's expression from the home-manager tree, by a
  # path relative to the tests; both trees keep their places under `modules/`.
  ''
    mkdir -p modules/.common.d modules/home-manager
    cp -r ${./..} modules/.common.d/ssh-keys.d
    cp -r ${../../../home-manager/ssh-key.d} modules/home-manager/ssh-key.d
    chmod -R u+w modules
    cd modules/.common.d/ssh-keys.d/tests && HOME=$TMPDIR bats .
    touch $out
  ''
