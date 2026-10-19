# ndh-incus-container's bats as a flake check: incus, zfs stubbed; no incus call waits on an open stdin.
{ pkgs }:
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
  }
  ''
    cp -r ${./..} incus-nixos-container.d && chmod -R u+w incus-nixos-container.d
    cd incus-nixos-container.d/tests && HOME=$TMPDIR bats --print-output-on-failure .
    touch $out
  ''
