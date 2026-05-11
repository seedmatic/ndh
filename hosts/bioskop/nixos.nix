{ ... }:
{
  config = {
    # Cachix watch-store token for auto-push of locally-built paths to
    # our nxmatic.cachix.org cache. Token path traced back to the repo's
    # .secrets file (SOPS-encrypted).
    services.nxmaticCachixWatchStore.sopsEncryptedTokenFile = ../../.secrets;

    # Cache signing (private deploy + trusted-public-keys + /etc/nix/*.pub)
    # is wired fleet-wide in modules/.common.d/nix-signing.nix — nothing
    # host-specific here.

    # Vector observability agent forwards build events to Darwin aggregator
    bringupObserve = {
      enable = true;
      # Forward to Darwin host Vector aggregator via VM network gateway
      # VM NAT makes the macOS host accessible at 192.168.5.2
      upstreamEndpoint = "http://192.168.5.2:9001";
    };
  };
}
