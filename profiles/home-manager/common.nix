{ profile, config, pkgs, lib, ... }: {

  options.profile = lib.mkOption {
    type = lib.types.submodule {
      options = {
        name = lib.mkOption { 
          type = lib.types.str; 
        };
        description = lib.mkOption { 
          type = lib.types.str; 
        };
        email = lib.mkOption { 
          type = lib.types.str; 
        };
        username = lib.mkOption { 
          type = lib.types.str; 
        };
      };
    };

    default = profile;
  };

  config.profile = profile;

}
