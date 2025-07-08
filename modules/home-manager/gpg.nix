{ lib, ... }: {
  programs.gpg = {
    enable = true;
    settings = { use-agent = true; };
  };

  services.gpg-agent = {
    enable = lib.mkDefault false;
    defaultCacheTtl = 1800;
    enableSshSupport = false;
    extraConfig = ''
      allow-loopback-pinentry
    '';
  };
}
