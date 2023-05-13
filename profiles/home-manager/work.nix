{pkgs, ...}: {
  home.packages = with pkgs; [
    cacert
    kubectl
    kubernetes-helm
    kustomize
    krew
    vault-bin
  ];
  home.sessionVariables = rec {
    NIX_SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";
    SSL_CERT_FILE = NIX_SSL_CERT_FILE;
    REQUESTS_CA_BUNDLE = NIX_SSL_CERT_FILE;
    PIP_CERT = NIX_SSL_CERT_FILE;
    GIT_SSL_CAINFO = NIX_SSL_CERT_FILE;
    NODE_EXTRA_CA_CERTS = NIX_SSL_CERT_FILE;
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
        signByDefault = true;
      };
      extraConfig = {
        http.sslVerify = true;
        http.sslCAInfo = "/etc/ssl/certs/ca-certificates.crt";
      };
    };
    # kubernetes
    krew.enable = true;
  };
}
