{ hostProfile, darwinProfile }:
{
  lib,
  config,
  ...
}:
{
  imports = [
    (import ../host-common.nix {
      inherit hostProfile darwinProfile;
      headscaleServerUrl = "http://192.168.1.193:8080";
    })
  ];
  config = {
    # Runtime host: participates in both the system-scope and user-scope
    # profiles. See profile.nix for the semantics.
    profile.names = lib.mkForce [
      "system"
      "user"
    ];

    # Keep experiment/bootstrap mode until boot/login validation is complete.
    # This avoids stage-2 panic when /etc/sops/age/keys.txt is not yet provisioned.
    ndh.sopsAgeKeyBootstrap.phase = "bootstrap";
    ndh.sopsAgeKeyBootstrap.nixosHostKeyImport.candidates = [
      # Preferred: key delivered via Tart host share.
      "/mnt/tart-cidata/sops.d/age/keys.txt"
      # Host-mounted fallback: ~/Private/sops:age:keys.txt on Darwin host.
      "/Users/nxmatic/.config/sops/age/keys.txt"
    ];

    # Safety valve while exercising fresh SSH/runtime-secret changes.
    opensshPolicy.passwordAuthentication = true;

    nix.settings = {
      trusted-users = [
        "root"
        "nxmatic"
      ];
    };
  };
}
