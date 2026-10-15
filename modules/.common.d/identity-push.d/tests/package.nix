# ndh-identity-push's bats suite as a flake check: the real push and receive, the outside world stubbed.
{ pkgs }:
pkgs.runCommand "identity-push-bats"
  {
    nativeBuildInputs = with pkgs; [
      age
      bats
      bash
      coreutils
      findutils
      gawk
      gnugrep
      gnused
      openssh
      ssh-to-age
    ];
  }
  ''
    cp -r ${./..} identity-push.d && chmod -R u+w identity-push.d
    cd identity-push.d/tests && HOME=$TMPDIR bats .
    touch $out
  ''
