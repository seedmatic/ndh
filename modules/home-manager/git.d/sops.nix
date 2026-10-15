# The git sops drivers (./git-sops-diff.nix): a textconv per format, so the operator's `git diff` of
# a sops file shows it decrypted, and the yaml/binary clean+smudge filters, active only where a
# .gitattributes names them (keyhole; never a repository holding a flake, at any depth). The package bakes
# its own store path, so one global include wires them all. Claude Code sessions neutralise them
# (sops-git-env.sh).
{
  pkgs,
  ...
}:
let
  gitSopsDiff = pkgs.callPackage ./git-sops-diff.nix { };
in
{
  programs.git.includes = [ { path = "${gitSopsDiff}/sops"; } ];
}
