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
      # No `headscaleServerUrl` override — fall through to
      # `catalog.headscale.aliasUrl` (mammoth-skate.duckdns.org:41841),
      # which works universally for all hosts (on-LAN via NAT hairpinning,
      # off-LAN via WAN port forward).
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

    # The NixOS guest does not receive an identity from the vz host at all — it decrypts
    # with one generated on itself. See nixos.nix.

    nix.settings = {
      trusted-users = [
        "root"
        "nxmatic"
      ];
    };

    # Headscale role assignments are Darwin-specific — they live in
    # hosts/nikopol/darwin.nix so the NixOS VM does not inherit the
    # role and run a second daemon.
  };
}
