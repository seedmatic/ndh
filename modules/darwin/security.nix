{ ... }:

{
  config = {
    environment.etc = {
      "sudoers.d/%admin".text = ''
        Defaults:%admin timestamp_timeout=240
      '';
      "sudoers.d/nxmatic-nopasswd".text = ''
        nxmatic ALL=(ALL) NOPASSWD: ALL
      '';
    };
    security.pam.services.sudo_local.touchIdAuth = true;
  };
}
