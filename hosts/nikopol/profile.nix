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

    # The NixOS guest does not receive an identity from the vz host at all — it decrypts
    # with its own, placed by the operator from their keyring. See nixos.nix.

    # Headscale role assignments are Darwin-specific — they live in
    # hosts/nikopol/darwin.nix so the NixOS VM does not inherit the
    # role and run a second daemon.
  };
}
