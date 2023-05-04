{pkgs, ...}: {

  user.name = "nxmatic";

  hm = {
    imports = [
      ./home-manager/work.nix
      ./home-manager/committed.nix
    ];
  };

  security.pki.certificateFiles = [
    "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
    "/etc/certs.d/apl.pem"
    "/etc/certs.d/dod-chain.pem"
  ];

}
