# ndh-vz-recover's bats suite as a flake check, on the Linux builder: stubbed tart and open, then a REAL sshd on
# loopback serving the package's own authorized_keys options (on darwin, sshd's preauth child cannot enter its
# seatbelt sandbox inside the nix build sandbox).
{ pkgs, authorizedOptions }:
pkgs.runCommand "vz-recover-bats"
  {
    NSS_WRAPPER_LIB = "${pkgs.nss_wrapper}/lib/libnss_wrapper.so";
    AUTHORIZED_OPTIONS = authorizedOptions "@COMMAND@";
    nativeBuildInputs = with pkgs; [
      bats
      bash
      coreutils
      gnugrep
      openssh
    ];
  }
  ''
    cp -r ${./..} vz-recover.d && chmod -R u+w vz-recover.d
    cd vz-recover.d/tests && bats --print-output-on-failure .
    touch $out
  ''
