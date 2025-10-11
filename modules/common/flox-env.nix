{ config, lib, pkgs, ... }:

let
  inherit (lib) mkEnableOption mkOption types mkIf;
  cfg = config.programs.floxEnv;

  # Use a safe default path that works in both Darwin and Home Manager contexts
  defaultProjectRoot =
    if config ? home && config.home ? homeDirectory
    then "${config.home.homeDirectory}/Gits/nxmatic/nix-darwin-home"
    else "${config.profile.user.home}/Gits/nxmatic/nix-darwin-home";  # use profile-provided user home
in
{
  options.programs.floxEnv = {
    enable = mkEnableOption "Declarative flox environment management";

    environmentName = mkOption {
      type = types.str;
      default = "nix-darwin-home";
      description = "Name of the flox environment";
    };

    packages = mkOption {
      type = types.listOf (types.submodule {
        options = {
          name = mkOption {
            type = types.str;
            description = "Package install name";
          };
          pkg-path = mkOption {
            type = types.str;
            description = "Nixpkgs attribute path";
          };
          systems = mkOption {
            type = types.nullOr (types.listOf types.str);
            default = null;
            description = "Supported systems (optional)";
          };
        };
      });
      default = [];
      description = "List of packages to install in the flox environment";
    };

    supportedSystems = mkOption {
      type = types.listOf types.str;
      default = [ "aarch64-darwin" "aarch64-linux" "x86_64-darwin" "x86_64-linux" ];
      description = "Supported systems for the flox environment";
    };

    projectRoot = mkOption {
      type = types.str;
      default = defaultProjectRoot;
      description = "Root directory where the flox environment should be created";
    };
  };

  config = mkIf cfg.enable {
    # This module only provides options and configuration data
    # Actual flox environment management is handled by:
    # - modules/home-manager/flox-direnv.nix for Home Manager integration
    # - The flox tool itself via direnv integration

    # Export configuration for other modules to use
    programs.floxEnv = {
      # Configuration is available to other modules that import this
    };
  };
}
