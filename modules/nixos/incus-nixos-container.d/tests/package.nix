# ndh-incus-container's bats as a flake check, through the real trampoline and logger: incus, zfs, nix and systemctl
# stubbed, and the CLI run under the PATH it has on the guest, never the sandbox's (a bare `bash` reached the guest
# that way, 2026-10-22).
{ pkgs, trampoline }:
pkgs.runCommand "incus-nixos-container-bats"
  {
    nativeBuildInputs = with pkgs; [
      bash
      bats
      coreutils
      gnugrep
      gnused
      yq-go
    ];
    NDH_TRAMPOLINE = trampoline;
    NDH_BOOTSTRAP_PROFILE_DIR = import ../../../.common.d/shell.d/tests/bootstrap-profile.nix {
      inherit pkgs;
    };
    # The guest system's own tools the CLI reaches besides the stubbed ones, as /run/current-system/sw/bin gives them.
    NDH_TEST_SYSTEM_SW = pkgs.symlinkJoin {
      name = "ndh-incus-container-test-sw";
      paths = with pkgs; [
        coreutils
        findutils
        util-linux
      ];
    };
  }
  ''
    cp -r ${./..} incus-nixos-container.d && chmod -R u+w incus-nixos-container.d
    cd incus-nixos-container.d/tests && HOME=$TMPDIR bats --print-output-on-failure .
    touch $out
  ''
