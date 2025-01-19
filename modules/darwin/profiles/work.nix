{ config, lib, pkgs, ... }: {

  imports = [ 
    (import ./common.nix { 
      inherit config lib pkgs; 

      profile = {
        name = "work";
        user = {
          name = "stephane.lacoin";
          email = "stephane.lacoin@hyland.com";
          description = "Stephane Lacoin (aka nxmatic)";
        };
      };

    }) 
  ];

  ids.gids.nixbld = 30000;

}
