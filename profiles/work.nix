{pkgs, ...}: {
  user.name = "nxmatic";
  hm = {imports = [./home-manager/work.nix ./home-manager/personal.nix];};

  security.pki.certificateFiles = ["${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt" "/etc/certs.d/apl.pem" "/etc/certs.d/dod-chain.pem"];
}
