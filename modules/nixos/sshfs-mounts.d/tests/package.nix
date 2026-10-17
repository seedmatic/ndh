# The read-only sftp proof as a flake check: a real sftp client against nixpkgs' sftp-server -R, the same
# read-only code the seat's forced internal-sftp -R runs.
{ pkgs }:
pkgs.runCommand "sshfs-read-only-sftp-bats"
  {
    nativeBuildInputs = with pkgs; [
      bats
      bash
      coreutils
      findutils
      openssh
    ];
  }
  ''
    cp -r ${./.} tests && chmod -R u+w tests
    cd tests && HOME=$TMPDIR SFTP_SERVER=${pkgs.openssh}/libexec/sftp-server bats read-only-sftp.bats
    touch $out
  ''
