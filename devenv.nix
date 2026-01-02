{
  self,
  pkgs,
  ...
}:
{
  devenv.root = "/tmp";

  packages = [
    pkgs.nixd
    pkgs.flox
    pkgs.lima
    pkgs.direnv
    self.packages.${pkgs.stdenv.hostPlatform.system}.pyEnv
  ];

  pre-commit = {
    hooks = {
      black.enable = true;
      shellcheck.enable = true;
      alejandra.enable = true;
      shfmt.enable = false;
      stylua.enable = true;
      deadnix = {
        enable = true;
        settings = {
          edit = true;
          noLambdaArg = true;
        };
      };
    };
  };
}
