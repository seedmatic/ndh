{
  config,
  pkgs,
  lib,
  ...
}:
{
  config = {
    # Bootstrap cache signing key on NixOS guests if missing.
    # The secret key remains local at /etc/nix and is not stored in the Nix store.
    services.nxmaticCachixWatchStore.sopsEncryptedTokenFile = ../../.secrets;
    nix.settings.secret-key-files = [ "/etc/nix/bioskop-cache.key" ];
    system.activationScripts.ensureBioskopCacheKey = ''
      if [ ! -s /etc/nix/bioskop-cache.key ] || [ ! -s /etc/nix/bioskop-cache.pub ]; then
        install -d -m 0755 /etc/nix
        ${pkgs.nix}/bin/nix-store --generate-binary-cache-key \
          bioskop-cache \
          /etc/nix/bioskop-cache.key \
          /etc/nix/bioskop-cache.pub
        chmod 600 /etc/nix/bioskop-cache.key
        chmod 644 /etc/nix/bioskop-cache.pub
      fi
    '';

    # Vector observability agent forwards build events to Darwin aggregator
    bringupObserve = {
      enable = true;
      # Forward to Darwin host Vector aggregator via VM network gateway
      # VM NAT makes the macOS host accessible at 192.168.5.2
      upstreamEndpoint = "http://192.168.5.2:9001";
    };
  };
}
