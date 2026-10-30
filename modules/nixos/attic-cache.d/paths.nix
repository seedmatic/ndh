# Where the cache container's dataset sits on its NixOS guest. One definition for the two sides
# that name it: the module that mounts it and the guest's publisher (attic-cache.nix), which publishes the cache's
# public from it.
rec {
  hostRoot = "/var/lib/ndh-attic";
  hostShared = "${hostRoot}/shared";
  # Where this guest publishes its cache's public for keys-reconcile: its own directory, never host-key's.
  publishDir = "/var/lib/ndh/attic/published";
}
