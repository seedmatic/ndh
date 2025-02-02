{ config, lib, pkgs, ... }:
with lib;
let
  cfg = config.services.emacsDaemon;
in {
  options = {
    services.emacsDaemon = {

      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Enable the emacs daemon agent.";
      };

    };
  };

  config = mkIf cfg.enable {

    launchd.agents.emacs-daemon = {
      enable = true;
      config = {
        Label = "org.nix-community.home.emacs-daemon";
        ProgramArguments = [ "${pkgs.emacs}/bin/emacs" "--fg-daemon" ];
        RunAtLoad = true;
        KeepAlive = true;
      };

    };
  };
}
