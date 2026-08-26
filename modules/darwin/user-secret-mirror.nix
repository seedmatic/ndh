# Generic user-scoped secret mirror (@codebase).
#
# sops-nix only lands decrypted secrets under /run/secrets — a tmpfs whose
# directory needs root to traverse, and which a user process (or an incus
# container that automounts the operator's home, not the darwin /run) cannot
# reach. Several consumers need the SAME secret as a persistent, user-owned file
# OUTSIDE /run. modules/darwin/ssh-keys-enrichment.nix solved that for the SSH
# keys with a postActivation copy; this module GENERALISES just that copy step —
# no yaml split, no enrichment — for any secret.
#
# For each entry, after sops-install-secrets has materialised `source` under
# /run/secrets, a postActivation step installs a standalone copy at `target`
# (persistent home path, owner-readable). The copy survives reboots (the home is
# not tmpfs); a `darwin-rebuild` re-copies, so a rotated secret propagates.
{
  config,
  lib,
  ...
}:

let
  cfg = config.ndh.userSecretMirror;

  mirrorSubmodule = lib.types.submodule {
    options = {
      source = lib.mkOption {
        type = lib.types.str;
        description = "The /run/secrets path sops-nix materialised (the decrypted source).";
      };
      target = lib.mkOption {
        type = lib.types.str;
        description = "The persistent, user-owned destination (outside /run).";
      };
      owner = lib.mkOption {
        type = lib.types.str;
        default = config.profile.user.name;
        description = "Unix user that owns the mirrored copy (defaults to the profile user).";
      };
      mode = lib.mkOption {
        type = lib.types.str;
        default = "0400";
        description = "File permissions for the mirrored copy.";
      };
    };
  };

  mirrorStep = name: m: ''
    if [ -r ${lib.escapeShellArg m.source} ]; then
      install -d -m 0700 -o ${lib.escapeShellArg m.owner} ${lib.escapeShellArg (builtins.dirOf m.target)}
      install -m ${lib.escapeShellArg m.mode} -o ${lib.escapeShellArg m.owner} ${lib.escapeShellArg m.source} ${lib.escapeShellArg m.target}
    else
      echo "userSecretMirror ${name}: source not readable at ${m.source} (sops did not materialise it?)" >&2
    fi
  '';
in
{
  options.ndh.userSecretMirror = lib.mkOption {
    type = lib.types.attrsOf mirrorSubmodule;
    default = { };
    description = ''
      Mirror sops-nix system secrets (which only land under /run/secrets) to
      persistent, user-owned files a user process or an automounted container can
      reach. The generalisation of the SSH-keys extract copy step.
    '';
  };

  # mkOrder 1450: after sops-install-secrets (~1000) and the ssh-keys system
  # extract (1400), before nothing in particular — the source must exist by now.
  config = lib.mkIf (cfg != { }) {
    system.activationScripts.postActivation.text = lib.mkOrder 1450 (
      lib.concatStringsSep "\n" (lib.mapAttrsToList mirrorStep cfg)
    );
  };
}
