{ profileName, ... }: 
let
  result = {

    hm = {
      imports = [
        ../home-manager/${profileName}.nix
      ];
    };

  };
in
  builtins.trace "Finished evaluating profiles/darwin/${profileName}.nix" result
