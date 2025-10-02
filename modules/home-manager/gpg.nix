{ lib, config, ... }: {
  programs.gpg = {
    enable = true;
    homedir = "${config.xdg.dataHome}/gnupg";
    settings = { use-agent = true; };
  };

  services.gpg-agent = {
    enable = true;
    defaultCacheTtl = 1800;
    enableSshSupport = false;
    extraConfig = ''
      allow-loopback-pinentry
    '';
  };
}
