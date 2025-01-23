{ pkgs, ... }: {

  # Base git configuration that can be extended
  programs.git = {
    enable = true;
    lfs.enable = true;
    extraConfig = {
      http.sslVerify = true;
      http.sslCAInfo = "/etc/ssl/certs/ca-certificates.crt";
    };
  };
}
