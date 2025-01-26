{ profile, config, lib, pkgs, ... }: {

  hm = {
    imports = [ 
      (import ../home-manager/common.nix { 
        inherit profile config lib pkgs; 
      }) 
    ];

    programs.git = {
      userEmail = profile.email;
      userName = profile.description;
      signing = {
        key = profile.email;
        signByDefault = false;
      };
    };
  };
    
  user = {
    name = profile.username;
    description = profile.description;
  };
}
