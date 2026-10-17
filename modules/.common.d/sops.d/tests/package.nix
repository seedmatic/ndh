# The age bootstrap's bats suite as a flake check: the script rendered with test paths, age-keygen and
# chown stubbed.
{ pkgs }:
pkgs.runCommand "sops-age-bootstrap-bats"
  {
    nativeBuildInputs = with pkgs; [
      bats
      bash
      coreutils
      gnused
      gnugrep
    ];
  }
  ''
    cp -r ${./..} sops.d && chmod -R u+w sops.d
    cd sops.d/tests && HOME=$TMPDIR bats --print-output-on-failure .
    touch $out
  ''
