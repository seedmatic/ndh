{ config, home-manager, pkgs, lib, ... }:

let
  inherit (pkgs) stdenv;
  inherit (lib) mkIf;
  cfg = config.profile;
  defaultUserHome =
    if stdenv.isDarwin then "Users" else "${config.users.defaultUserHome}";
  
  # Shared user profile mapping (@codebase)
  # This defines the mapping between different profiles and their corresponding usernames
  # Used by both profile configurations and symlink modules
  userMapping = {
    # Profile name -> user configuration mapping
    profileUsers = {
      work = {
        name = "stephane.lacoin";
        description = "Stephane Lacoin (aka nxmatic)";
        email = "stephane.lacoin@hyland.com";
      };
      
      committed = {
        name = "nxmatic"; 
        description = "Stephane Lacoin (aka nxmatic)";
        email = "stephane.lacoin@gmail.com";
      };
    };
  };
in {
  options = {
    profile = lib.mkOption {
      description = "Profile currently evaluated";
      type = lib.types.submodule {
        options = {
          name = lib.mkOption {
            type = lib.types.str;
            description = "The name of the profile";
            default = "jdoe";
          };
          email = lib.mkOption {
            type = lib.types.str;
            description = "The email of the user";
            default = lib.mkDefault
              (cfg.email or "${cfg.user.name or "user"}@example.com");
          };
          homeSymlinks = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            description = "List of alternative usernames to create symlinks for in /home";
            default = [];
            example = [ "nxmatic" ];
          };
          darwin = lib.mkOption {
            type = lib.types.submodule {
              options = {
                knownNetworkServices = lib.mkOption {
                  type = lib.types.listOf lib.types.str;
                  description = "List of known network services";
                  default =
                    [ "Wi-Fi" "Ethernet Adaptor" "Thunderbolt Ethernet" ];
                };
              };
            };
          };
          host = lib.mkOption {
            type = lib.types.submodule {
              options = {
                hostName = lib.mkOption {
                  type = lib.types.str;
                  description = "The name of the host";
                  default = "nameless-host";
                };
                hostAlias = lib.mkOption {
                  type = lib.types.str;
                  description = "An alias for the host";
                  default = cfg.host.hostName;
                };
                tailnet = lib.mkOption {
                  type = lib.types.submodule {
                    options = {
                      name = lib.mkOption {
                        type = lib.types.str;
                        description = "The name of the tailnet";
                        default = "mammoth-skate";
                      };
                      domain = lib.mkOption {
                        type = lib.types.str;
                        description = "The domain of the tailnet";
                        default = "ts.net";
                      };
                    };
                  };
                };
              };
            };
          };

          user = lib.mkOption {
            type = lib.types.submodule {
              options = {
                name = lib.mkOption {
                  type = lib.types.str;
                  description = "The name of the user";
                  default = "jdoe";
                };
                description = lib.mkOption {
                  type = lib.types.str;
                  description = "The description of the user";
                  default = "Default user ${cfg.user.name}";
                };
                shell = lib.mkOption {
                  type = lib.types.package;
                  description = "The shell of the user";
                  default = pkgs.bash;
                  example = "bash";
                };
                isNormalUser = lib.mkOption {
                  type = lib.types.bool;
                  description = "Whether the user is a normal user";
                  default = true;
                };
                isSystemUser = lib.mkOption {
                  type = lib.types.bool;
                  description = "Whether the user is a system user";
                  default = false;
                };
                group = lib.mkOption {
                  type = lib.types.str;
                  description = "The user primary group the user belongs to";
                  default = cfg.user.name;
                };
                home = lib.mkOption {
                  type = lib.types.path;
                  description = "The home directory of the user";
                  default =
                    builtins.toPath "/${defaultUserHome}/${cfg.user.name}";
                };
                homeMode = lib.mkOption {
                  type = lib.types.str;
                  description = "The home directory permissions";
                  default = "0755";
                };
              };
            };
          };
        };
      };
    };
  };
  
  # Make userMapping available to other modules
  config._module.args.userMapping = userMapping;
}
