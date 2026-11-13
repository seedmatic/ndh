{
  config,
  lib,
  pkgs,
  ...
}:
# No Mac of the fleet serves NFS — EXCEPT those exporting git stores (services.nfsDarwin.enable).
# When NFS is enabled, leave nfsd alone so it can serve exports; otherwise ensure it is gone.
lib.mkIf (!(config.services.nfsDarwin.enable or false)) (
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
)
