{ ... }: let
  profile = {
    name = "work";
    email = "stephane.lacoin@hyland.com";
    username = "stephane.lacoin";
  };
in {

  imports = [
    (import ./common.nix { inherit profile; }) 
  ];

}

