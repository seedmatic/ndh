# ndh-host-key-generate's bats suite as a flake check, on throwaway keys, through the real trampoline and logger
# (handed over: the sandbox cannot search the store for it).
{ pkgs, trampoline }:
pkgs.runCommand "host-key-generate-bats"
  {
    nativeBuildInputs = with pkgs; [
      bats
      bash
      coreutils
      findutils
      gnugrep
      gnused
      hostname
      openssh
    ];
    NDH_TRAMPOLINE = trampoline;
    NDH_BOOTSTRAP_PROFILE_DIR = import ../../shell.d/tests/bootstrap-profile.nix { inherit pkgs; };
  }
  ''
    cp -r ${./..} host-key.d && chmod -R u+w host-key.d
    cd host-key.d/tests && HOME=$TMPDIR bats --print-output-on-failure generate.bats
    touch $out
  ''
