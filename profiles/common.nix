
{ home-manager, pkgs, lib, config, ... }:

let
  inherit (pkgs) stdenv;
  inherit (lib) mkIf;
  cfg = config.profile;
  defaultUserHome = if stdenv.isDarwin then "Users" else "${config.users.defaultUserHome}";
in {
  options = {
    profile = lib.mkOption {
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
          host = lib.mkOption {
            type = lib.types.submodule {
              options = {
                name = lib.mkOption {
                  type = lib.types.str;
                  description = "The name of the host";
                  default = lib.mkDefault cfg.host.name;
                };
                tailnet = lib.mkOption {
                  type = lib.types.submodule {
                    options = {
                      name = lib.mkOption {
                        type = lib.types.str;
                        description = "The name of the tailnet";
                        default = lib.mkDefault cfg.tailnet.name;
                      };
                      domain = lib.mkOption {
                        type = lib.types.str;
                        description = "The domain of the tailnet";
                        default = lib.mkDefault cfg.tailnet.domain;
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
                  default = lib.mkDefault (cfg.user.name or "user");
                };
                description = lib.mkOption {
                  type = lib.types.str;
                  description = "The description of the user";
                  default = lib.mkDefault
                    (cfg.user.description or "User ${cfg.user.name or "user"}");
                };
                shell = lib.mkOption {
                  type = lib.types.package;
                  description = "The shell of the user";
                  default = lib.mkDefault
                    (cfg.user.shell or cfg.users.shell or pkgs.bash);
                };
                isNormalUser = lib.mkOption {
                  type = lib.types.bool;
                  description = "Whether the user is a normal user";
                  default = lib.mkDefault (cfg.user.isNormalUser or true);
                };
                isSystemUser = lib.mkOption {
                  type = lib.types.bool;
                  description = "Whether the user is a system user";
                  default = lib.mkDefault (cfg.user.isSystemUser or false);
                };
                group = lib.mkOption {
                  type = lib.types.str;
                  description = "The user primary group the user belongs to";
                  default =
                    lib.mkDefault (cfg.user.group or (cfg.user.name or "user"));
                };
                home = lib.mkOption {
                  type = lib.types.path;
                  description = "The home directory of the user";
                  default = builtins.toPath "/${defaultUserHome}/${cfg.user.name or "user"}";
                };
                homeMode = lib.mkOption {
                  type = lib.types.str;
                  description = "The home directory permissions";
                  default = lib.mkDefault (cfg.user.homeMode or "0755");
                };
              };
            };
          };
        };
      };

      description = "Profile currently evaluated";
    };

  };

}
