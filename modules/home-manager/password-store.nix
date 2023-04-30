{
  config,
  pkgs,
  ...
}: let
  home = config.home.homeDirectory;
  store = home + "/.local/share/password-store";
in {
  programs.password-store = {
    enable = true;
    package = pkgs.pass.withExtensions (exts: [
      exts.pass-otp
    ]);
    settings = {
      PASSWORD_STORE_DIR = "${store}";
      #       PASSWORD_STORE_KEY = "12345678";
      PASSWORD_STORE_CLIP_TIME = "60";
    };
  };
}
