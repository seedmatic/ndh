{
  pkgs,
  ...
}:
# No Mac of the fleet serves NFS. The guests reach the operator seats' git stores over sshfs since ndh
# 2e5bb326, which deleted the NFS module but left its state: /etc/exports kept exporting /private and
# /Users to the LAN and the tailnet, and nfsd kept running. Every activation now ensures it is gone.
let
  nfsdOff = pkgs.writeShellApplication {
    name = "nfsd-off";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gnugrep
    ];
    text = builtins.readFile ./nfsd-off.d/nfsd-off.sh;
  };
in
{
  system.activationScripts.postActivation.text = ''
    ${nfsdOff}/bin/nfsd-off /etc/exports /sbin/nfsd
  '';
}
