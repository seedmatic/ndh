{
  config,
  pkgs,
  ...
}: let
  home = config.home.homeDirectory;
  store = home + "/.local/share/password-store";
in
  builtins.traceVerbose "Importing password-store.nix" {
    programs.password-store = {
      enable = true;
      package = pkgs.pass.withExtensions (exts: [
        exts.pass-audit
        exts.pass-checkup
        exts.pass-file
        exts.pass-genphrase
        exts.pass-import
        exts.pass-update
        exts.pass-otp
      ]);
      settings = {
        PASSWORD_STORE_DIR = "${store}";
        PASSWORD_STORE_CLIP_TIME = "60";
        PASSWORD_STORE_ENABLE_EXTENSIONS = "true";
      };
    };
  }
