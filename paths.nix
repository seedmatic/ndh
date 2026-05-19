# Path registry for static repo files used as runtime data by NixOS/Darwin
# modules.  Each value is a Nix path literal — `nix` evaluates it to a store
# path whose hash depends ONLY on the file (or directory subtree) imported,
# never on the rest of the worktree.
#
# Why not use `${self}/<file>`?  `self` is a flake input whose hash captures
# the whole git tree, so any unrelated edit (a README typo, a comment in
# `flake.nix`) re-hashes every `"${self}/foo"` reference and forces the
# downstream NixOS module — and thus the bringup disk image — to rebuild.
# Path literals here narrow that input footprint per file.
#
# When you reach for a new "${self}/path" in a module, add it here instead
# and consume `paths.<name>` via the module's argument list.  See
# docs/bringup-image-unification.adoc for the broader byte-stability rationale.
{
  catalogCacheTrust = ./catalog/cache-trust.nix;
}
