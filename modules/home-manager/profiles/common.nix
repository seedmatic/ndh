{ lib, config, ... }: let

cfg = config.profile;

in
{
  options = {
    profile = lib.mkOption {
      type = lib.types.submodule {
        options = {
          name = lib.mkOption {
            type = lib.types.str;
            description = "The name of the profile";
            default = "jdoe";
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
                  default = lib.mkDefault cfg.user.name;
                };
                email = lib.mkOption {
                  type = lib.types.str;
                  description = "The email of the user";
                  default = lib.mkDefault cfg.user.email;
                };
                description = lib.mkOption {
                  type = lib.types.str;
                  description = "The description of the user";
                  default = lib.mkDefault cfg.user.description;
                };
                home = lib.mkOption {
                  type = lib.types.path;
                  description = "The home directory of the user";
                  default = lib.mkDefault cfg.user.home;
                };
                shell = lib.mkOption {
                  type = lib.types.package;
                  description = "The shell of the user";
                  default = lib.mkDefault cfg.user.shell;
                };
              };
            };
          };
        };
      };

      description = "Profile currently evaluated";
    };

    hm = lib.mkOption {
      type = lib.types.attrs;
      description = "Home Manager configuration";
      default = lib.mkDefault cfg.hm;
    };

  };

}