{lib, pkgs, ...}: mkMerge [
  import ./committed.nix;
  {
    user.name = "nxmatic";

    hm = {
      imports = [
        ../home-manager/committed.nix
        ../home-manager/work.nix
      ];
    };
    
    security.pki.certificateFiles = [
      "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
      "/etc/certs.d/apl.pem"
      "/etc/certs.d/dod-chain.pem"
    ];
  }
}
