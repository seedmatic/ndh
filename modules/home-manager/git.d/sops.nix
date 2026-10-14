# The git sops diff driver (./git-sops-diff.nix): a textconv per format, so the operator's
# `git diff` of a sops file shows it decrypted. The package bakes its own store path, so one
# global include wires every format. Claude Code sessions neutralise it (sops-git-env.sh).
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
