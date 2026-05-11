{
  self,
  ...
}:
# Fleet-wide nix store signing: every NDH host uses the shared
# `io-nxmatic-nix-darwin-home` cachix keypair.
#
#   - private → deployed by sops-nix from catalog/cache-trust.yaml
#     (declared in modules/.common.d/sops.nix)
#   - public  → written declaratively from the plaintext value in
#     catalog/cache-trust.nix so the on-disk pub cannot drift from the
#     catalog silently.
#
# nix-daemon's secret-key-files is wired here so any host importing this
# module signs outgoing paths without additional per-host configuration.
let
  cacheTrust = import "${self}/catalog/cache-trust.nix";
  cachix = cacheTrust.caches.cachix."io-nxmatic-nix-darwin-home";
in
{
  nix.settings = {
    # Sign outgoing store paths with the shared fleet key.
    secret-key-files = [ "/etc/nix/io-nxmatic-nix-darwin-home.key" ];
    # Trust signatures produced by any other fleet host (same key).
    trusted-public-keys = [ cachix.publicKey ];
  };
  environment.etc."nix/io-nxmatic-nix-darwin-home.pub".text = cachix.publicKey + "\n";
}
