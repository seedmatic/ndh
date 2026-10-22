# Where the cache container's dataset sits on its NixOS guest. One definition for the two sides
# that name it: the module that mounts it (attic-cache.nix) and the operator seat's signer that
# fetches the CSR from it and installs the leaf into it (modules/.common.d/attic-leaf.d).
rec {
  hostRoot = "/var/lib/ndh-attic";
  hostTls = "${hostRoot}/tls";
  # Where this guest publishes its cache's public for keys-reconcile: its own directory, never host-key's.
  publishDir = "/var/lib/ndh/attic/published";
}
