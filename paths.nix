# Path registry for static repo files used as runtime data by NixOS/Darwin
# modules.  Resolves a relative path to a Nix path literal anchored at
# the repo root, whose hash depends ONLY on the imported file (or
# subtree), not on the rest of the worktree.
#
# Why not use `${self}/<file>`?  `self` is a flake input whose hash
# captures the whole git tree, so any unrelated edit (a README typo, a
# comment in `flake.nix`) re-hashes every `"${self}/foo"` reference and
# forces the bringup disk image to rebuild.  This narrows the input
# footprint per file.
#
# Usage:
#
#   paths.at "modules/.common.d/sops.nix"
#
# Returns the path literal `./<rel>`, suitable as an `imports = [ ... ]`
# entry, an argument to `import`, or `pkgs.replaceVars`, etc.  Inside
# string interpolation, use `"${paths.at "<rel>"}"`.
#
# See docs/bringup-image-unification.adoc for the byte-stability
# rationale.
let
  root = ./.;
in
{
  at = rel: root + "/${rel}";
}
