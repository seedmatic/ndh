{
  config,
  pkgs,
  ...
}:
let
  store = "${config.home.homeDirectory}/.local/share/password-store";
in
{
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
