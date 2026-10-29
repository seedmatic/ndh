# The git sops drivers (./git-sops-diff.nix): a textconv per format, so the operator's `git diff` of
# a sops file shows it decrypted, and the yaml/binary clean+smudge filters, active only where a
# .gitattributes names them (keyhole; never a repository holding a flake, at any depth). The package bakes
# its own store path, so one global include wires them all. Claude Code sessions neutralise them
# (sops-git-env.sh).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  gitSopsDiff = pkgs.callPackage ./git-sops-diff.nix { inherit (config.ndh.gitSops) ageSshKeyFile; };
in
{
  options.ndh.gitSops.ageSshKeyFile = lib.mkOption {
    type = lib.types.str;
    default = "";
    description = "keyring@keyhole's ssh private key, from which the filters derive keyhole's age identity (its ssh-to-age); empty where keyhole is not.";
  };

  config.programs.git.includes = [ { path = "${gitSopsDiff}/sops"; } ];
}
