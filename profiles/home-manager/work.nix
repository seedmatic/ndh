{pkgs, ...}: {
  home = {
    packages = with pkgs; [
      cacert
      kubectl
      kubernetes-helm
      kustomize
      krew
      vault-bin
    ];
    sessionPath = ["$HOME/.krew/bin"];
  };

  programs = {
    # version control

    git = {
      enable = true;
      lfs.enable = true;
      userEmail = "stephane.lacoin@hyland.com";
      userName = "Stephane Lacoin (aka nxmatic)";
      signing = {
        key = "stephane.lacoin@hyland.com";
        signByDefault = false;
      };
      extraConfig = {
        http.sslVerify = true;
        http.sslCAInfo = "/etc/ssl/certs/ca-certificates.crt";
      };
    };
  };
}
