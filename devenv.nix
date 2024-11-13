{
  self,
  pkgs,
  ...
}: {
  devenv.root = "/tmp";

  packages = [
    pkgs.nixd
    pkgs.flox
    self.packages.${pkgs.system}.pyEnv
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
