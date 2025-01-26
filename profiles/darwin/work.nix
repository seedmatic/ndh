{ profile, config, lib, pkgs, ... }: {

  imports = [ 
    (import ./common.nix { 
      inherit config lib pkgs profile; 
    }) 
  ];

  ids.gids.nixbld = 30000;

}
