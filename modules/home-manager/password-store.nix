{
  config,
  pkgs,
  lib,
  ...
}:
let
  store = "${config.home.homeDirectory}/.local/share/password-store";
in
{
  programs.password-store = {
    enable = true;
    package = pkgs.pass.withExtensions (
      exts:
      [
        exts.pass-audit
        exts.pass-checkup
        exts.pass-file
        exts.pass-genphrase
        exts.pass-update
        exts.pass-otp
      ]
      # pass-import pulls secretstorage → jeepney, the freedesktop Secret Service
      # (D-Bus) client — Linux-only. On darwin it is non-functional AND unbuildable
      # (jeepney's installCheck runs dbus-run-session, which macOS has no bus for).
      ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [ exts.pass-import ]
    );
    settings = {
      PASSWORD_STORE_DIR = "${store}";
      PASSWORD_STORE_CLIP_TIME = "60";
      PASSWORD_STORE_ENABLE_EXTENSIONS = "true";
    };
  };
}
