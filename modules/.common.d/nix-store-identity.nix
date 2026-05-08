{
  config,
  lib,
  pkgs,
  ndh,
  ...
}:
# Shared options + deploy script for the cert-signed nix-store identity.
# Data layer: the `nix-store` entry in keys.yaml (commit 530eb299) produces a
# rotating keypair signed by mammoth-skate. The per-user enrich+extract
# pipeline materializes:
#   ${secretsKeysDir}/nix-store            (private, 0600)
#   ${secretsKeysDir}/nix-store-cert.pub   (symlink → authority user cert)
#
# Consumers (nix-daemon --stdio, `nix copy`) expect the identity at a stable
# system path. Darwin wires the deploy script into a nix-darwin activation
# script; NixOS runs it from a systemd oneshot ordered after the extract
# service. Both call the same script so the copy policy stays in one place.
let
  cfg = config.nixStoreIdentity;
in
{
  imports = [ ./ssh-paths.nix ];

  options.nixStoreIdentity = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to expose the nix-store identity deploy helpers on this host.";
    };

    keyDir = lib.mkOption {
      type = lib.types.str;
      default = "/etc/nix";
      description = "Directory holding the deployed nix-store identity files.";
    };

    keyPath = lib.mkOption {
      type = lib.types.str;
      default = "${cfg.keyDir}/nix-store_ed25519";
      description = "Destination path for the deployed nix-store private key.";
    };

    certPath = lib.mkOption {
      type = lib.types.str;
      default = "${cfg.keyDir}/nix-store-cert.pub";
      description = "Destination path for the deployed nix-store user certificate.";
    };

    sourcePrivate = lib.mkOption {
      type = lib.types.str;
      default = "${config.sshPaths.secretsKeysDir}/nix-store";
      description = "Source path of the extracted private key (written by the enrich/extract pipeline).";
    };

    sourceCert = lib.mkOption {
      type = lib.types.str;
      default = "${config.sshPaths.secretsKeysDir}/nix-store-cert.pub";
      description = "Source path of the user certificate symlink (written by the enrich/extract pipeline).";
    };

    installGroup = lib.mkOption {
      type = lib.types.str;
      default = if pkgs.stdenv.isDarwin then "wheel" else "root";
      description = "Group ownership for files installed by the deploy script (wheel on Darwin, root on NixOS).";
    };

    deployScript = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      description = "Package exposing bin/nix-store-identity-deploy that installs the identity to its system paths.";
    };
  };

  config = lib.mkIf cfg.enable {
    nixStoreIdentity.deployScript = ndh.store.writeShellScriptBin "nix-store-identity-deploy" ''
      set -euo pipefail

      install -d -m 0755 "${cfg.keyDir}"

      if [ -f "${cfg.sourcePrivate}" ]; then
        install -m 0600 -o root -g ${cfg.installGroup} "${cfg.sourcePrivate}" "${cfg.keyPath}"
      else
        echo "nix-store-identity: private key not yet deployed at ${cfg.sourcePrivate}" >&2
      fi

      # Resolve the cert symlink before copying so the destination holds the
      # real contents rather than a link into the home-manager secrets tree.
      if [ -e "${cfg.sourceCert}" ]; then
        install -m 0644 -o root -g ${cfg.installGroup} "$(readlink -f "${cfg.sourceCert}")" "${cfg.certPath}"
      else
        echo "nix-store-identity: user certificate not yet deployed at ${cfg.sourceCert}" >&2
      fi
    '';
  };
}
