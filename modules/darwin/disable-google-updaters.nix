{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.services.disable-google-updaters;
  disableGoogleUpdatersScript = pkgs.writeTextFile {
    name = "disable-google-updaters";
    executable = true;
    destination = "/bin/disable-google-updaters";
    text = builtins.readFile ../../bin/disable-google-updaters.sh;
  };
  disableGoogleUpdatersActivationScript = pkgs.writeShellScript "disable-google-updaters-activation.sh" ''
    set -euo pipefail
    LOG="/var/log/darwin-disable-google-updaters.log"
    {
      echo "[google-updaters] Disabling Google update services"
      ${disableGoogleUpdatersScript}/bin/disable-google-updaters
    } >>"$LOG" 2>&1
  '';
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
      ${disableGoogleUpdatersActivationScript}
    '';
  };
}
