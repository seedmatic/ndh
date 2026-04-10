{ config, ... }:

let
  userName =
    if config ? profile && config.profile ? user && config.profile.user ? name then
      config.profile.user.name
    else
      "nxmatic";
in

{
  config = {
    environment.etc = {
      "sudoers.d/%admin".text = ''
        Defaults:%admin timestamp_timeout=240
      '';
      "sudoers.d/${userName}-nopasswd".text = ''
        ${userName} ALL=(ALL) NOPASSWD: ALL
      '';
    };
    security.pam.services.sudo_local.touchIdAuth = true;
  };
}
