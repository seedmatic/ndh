let
  cacheTrust = import ../../catalog/cache-trust.nix;
in
{
  substituters = [
    cacheTrust.caches.nixos.substituter
    cacheTrust.caches.nxmatic.substituter
  ];

  trusted-public-keys = [
    cacheTrust.caches.nixos.publicKey
    cacheTrust.caches.nxmatic.publicKey
  ];
}
