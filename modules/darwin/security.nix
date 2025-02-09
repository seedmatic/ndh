{ ... }:

{
  config = {
    environment.etc = {
      "sudoers.d/%admin".text = ''
        Defaults:%admin timestamp_timeout=240
      '';
    };
    security.pam.enableSudoTouchIdAuth = true;
  };
}


