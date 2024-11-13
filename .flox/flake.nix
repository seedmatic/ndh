{
  description = "Development environment with Flox";

  inputs = {
    nxmatic-flake-commons.url = "github:nxmatic/nix-flake-commons/develop";

    nixpkgs.follows = "nxmatic-flake-commons/nixpkgs";
  };

  outputs = {
    nixpkgs,
    flake-utils,
    ...
  }:
    flake-utils.lib.eachDefaultSystem (
      system: let
        pkgs = import nixpkgs {inherit system;};
      in {
        devShells.default = pkgs.mkShell {
          buildInputs = [
            pkgs.git
            pkgs.direnv
          ];
        };

        # Define a package output for print-dev-env
        packages.default = pkgs.stdenv.mkDerivation {
          name = "dev-env";
          buildInputs = [
            pkgs.git
            pkgs.direnv
          ];
        };
      }
    );
}
