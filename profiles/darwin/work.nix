{...}: let
  result = {
    user.name = "stephane.lacoin";
    hm = {
      imports = [
        ../home-manager/work.nix
      ];
    };
    homebrew = {
      enable = true;
      brews = [];
      casks = [];
    };
  };
in
  builtins.trace "Finished evaluating profiles/darwin/work.nix" result
