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

    # ⛔ No `nixosHostKeyImport.candidates` override here. There was one, listing
    # /mnt/tart-cidata/sops.d/age/keys.txt and /Users/nxmatic/.config/sops/age/keys.txt,
    # and BOTH paths are absent — measured inside the guest and on the host. It
    # therefore replaced a correct default with two dead entries, and the guest had no
    # working way to receive an operator identity at all: its /etc/sops/age/keys.txt sat
    # frozen on a single identity, and the remoteFetch fallback reads
    # /etc/sops/age/keys.txt on the vz host, which nikopol does not have either (its own
    # sops.age.keyFile is the operator's ~/.config, deliberately).
    #
    # The default from modules/.common.d/sops.nix already lists the share at its real
    # mount point — `/srv/host/sops.d/age/keys.txt`, virtiofs tag `ndh-sops-age` — which
    # is exactly what bioskop-nixos uses and why that guest receives new identities.

    # Safety valve while exercising fresh SSH/runtime-secret changes.
    opensshPolicy.passwordAuthentication = true;

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
