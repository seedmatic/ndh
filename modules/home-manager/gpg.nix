{pkgs, ...}: {
  programs.gpg = {
    enable = true;
    settings = {
      use-agent = true;
    };
  };

  services.gpg-agent = {
    enable = true;
    defaultCacheTtl = 1800;
    enableSshSupport = true;
    extraConfig = ''
      allow-loopback-pinentry
    '';
    pinentryPackage = pkgs.pinentry_mac;
  };
}
