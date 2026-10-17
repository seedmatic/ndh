# The read-only sftp proofs as a flake check, on the Linux builder: a real sftp client against nixpkgs'
# sftp-server -R, and against a REAL sshd on loopback serving the seat's own authorized_keys options (on
# darwin, sshd's preauth child cannot enter its seatbelt sandbox inside the nix build sandbox).
{ pkgs, authorizedOptions }:
pkgs.runCommand "sshfs-read-only-sftp-bats"
  {
    NSS_WRAPPER_LIB = "${pkgs.nss_wrapper}/lib/libnss_wrapper.so";
    AUTHORIZED_OPTIONS = authorizedOptions;
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
    cd tests && HOME=$TMPDIR SFTP_SERVER=${pkgs.openssh}/libexec/sftp-server bats --print-output-on-failure .
    touch $out
  ''
