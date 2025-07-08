{ lib, ... }: {
  
  disko = import ./disko-config.nix { inherit lib; }; 

}
