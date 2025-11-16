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
            # Keep a simple static default; we derive a dynamic one later in config (@codebase)
            default = lib.mkDefault "user@example.com";
          };
          homeSymlinks = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            description =
              "List of alternative usernames to create symlinks for in /home";
            default = [ ];
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
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  description = "Optional alias for the host (null means none).";
                  example = "my-mac";
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
                  # Simple default; dynamic form applied later (@codebase)
                  default = lib.mkDefault "Default user";
                };
                shell = lib.mkOption {
                  type = lib.types.package;
                  description = "The shell of the user";
                  default = pkgs.bash;
                  example = "bash";
                };
                uid = lib.mkOption {
                  type = lib.types.nullOr lib.types.int;
                  default = null;
                  description =
                    "Optional fixed UID to align with host (e.g. macOS UID 501/503).";
                };
                gid = lib.mkOption {
                  type = lib.types.nullOr lib.types.int;
                  default = null;
                  description =
                    "Optional fixed primary GID. Defaults to uid if set and gid is null.";
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
                  type = lib.types.nullOr lib.types.str;
                  description =
                    "Optional primary group name; if null a group matching the username should be created elsewhere";
                  default = null;
                };
                home = lib.mkOption {
                  type = lib.types.path;
                  description = "The home directory of the user";
                  # Static placeholder; dynamic path set in config phase (@codebase)
                  default = builtins.toPath "/${defaultUserHome}/jdoe";
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

  # Compose config: expose userMapping. Avoid self-reference causing recursion
  config = {
    _module.args.userMapping =
      userMapping; # (@codebase) keep simple to avoid recursion
    # Dynamic defaults (@codebase): adjust user home path to use the resolved user name
    # instead of the static placeholder jdoe so Home Manager's activation check matches $HOME.
    profile.user.home = lib.mkDefault (builtins.toPath "/${defaultUserHome}/${config.profile.user.name}");
  };
}
