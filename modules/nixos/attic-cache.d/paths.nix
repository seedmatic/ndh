# Where the cache container's dataset sits on its NixOS guest. One definition for the two sides
# that name it: the module that mounts it and the guest's publisher (attic-cache.nix), which publishes the CSR
# from it and installs the recorded leaf into it.
rec {
  hostRoot = "/var/lib/ndh-attic";
  hostTls = "${hostRoot}/tls";
  # Where this guest publishes its cache's public for keys-reconcile: its own directory, never host-key's.
  publishDir = "/var/lib/ndh/attic/published";
}
