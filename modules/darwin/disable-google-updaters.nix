{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.disable-google-updaters;
  disableGoogleUpdatersScript = pkgs.writeTextFile {
    name = "disable-google-updaters";
    executable = true;
    destination = "/bin/disable-google-updaters";
    text = builtins.readFile ../../bin/disable-google-updaters.sh;
  };
in
{
  options.services.disable-google-updaters = {
    enable = mkEnableOption "automatic disabling of Google update services (Keystone, Google Updater)";
  };

  config = mkIf cfg.enable {
    # Install the shared disable script into the system profile
    environment.systemPackages = [ disableGoogleUpdatersScript ];

    # Automatically disable Google update daemons on each activation (@codebase)
    system.activationScripts.postActivation.text = mkAfter ''
      ${disableGoogleUpdatersScript}/bin/disable-google-updaters
    '';
  };
}
