{ ... }: {
  imports = [ 
    (import ./common.nix { profileName = "work"; }) 
  ];
  
  user.name = "stephane.lacoin";
  ids.gids.nixbld = 30000;
}
