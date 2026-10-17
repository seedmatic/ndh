# A darwin host's side of the private caches: where the token delivery (roles x keys' S3b, its
# darwin twin reading this seat's own drop-box) puts its attic tokens. The same shape as the NixOS
# guests' ndh.atticClient.paths (modules/nixos/attic-client.nix); macOS has no /run tmpfs, and
# /var/run is emptied at every boot.
{ lib, ... }:
{
  options.ndh.atticClient.paths = lib.mkOption {
    readOnly = true;
    default = {
      dir = "/var/run/ndh-attic";
      # nix's netrc: one `machine <fqdn> password <read token>` per cache.
      netrc = "/var/run/ndh-attic/netrc";
      # The write token to this machine's own metalspace's cache.
      writeToken = "/var/run/ndh-attic/write.token";
    };
    description = "Where the token delivery puts this darwin host's attic tokens (root-only, emptied at boot).";
  };
}
