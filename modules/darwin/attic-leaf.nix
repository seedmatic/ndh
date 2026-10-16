{
  config,
  lib,
  pkgs,
  catalog,
  self,
  ...
}:
# The cache containers' TLS leaves on the operator seat: the one definition of attic-leaf-sign, on the
# operator's PATH, and run by this host's activation when it holds the TLS authority — the twin of
# incus-cluster-cert.nix.
#
# ⚠️ At activation the TLS authority's signing slot is used AUTOMATICALLY, as the operator (sudo -u),
# whenever a switch finds a cache serving no leaf, a leaf the fleet root did not issue or one that
# names anything but the cache — not on a date. The operator launches the switch, so it stays a
# gesture; the operator's sops identity decrypts keys.yaml, the operator's ssh identity reaches the
# NixOS guests.
let
  cfg = config.ndh.atticLeaf;
  user = config.profile.user.name;
  # The caches are the NixOS guests that declare one, each named by its own module (its catalog
  # `atticFqdn` by default) and reached by the guest's fabric FQDN.
  caches = lib.concatMap (
    host:
    let
      attic = self.nixosConfigurations."${host}-nixos".config.ndh.atticCache;
    in
    lib.optional attic.enable {
      inherit (attic) fqdn;
      via = catalog.netplan.baremetal.${host}.fabricFqdn;
    }
  ) (lib.attrNames catalog.netplan.baremetal);
in
{
  options.ndh.atticLeaf = {
    package = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = import ../.common.d/attic-leaf.d/package.nix {
        inherit pkgs lib caches;
        operatorIdentity = {
          inherit user;
          keyFile = config.sshPaths.privKeyFile;
          certFile = config.sshPaths.userCertPublic;
        };
      };
      description = "attic-leaf-sign, built for this operator seat's operator identity.";
    };
    atActivation = lib.mkEnableOption "signing the cache containers' TLS leaves at activation (the operator seat holding the TLS authority)";
  };

  config = lib.mkIf cfg.atActivation {
    environment.systemPackages = [ cfg.package ];
    system.activationScripts.postActivation.text = lib.mkOrder config.ndh.darwin.postActivationOrder.atticLeaf ''
      # A failure here is loud but does not stop the rest of the activation: a cache may be down.
      if ! /usr/bin/sudo -u ${lib.escapeShellArg user} -H \
        SOPS_AGE_KEY_FILE=${lib.escapeShellArg config.ndh.sopsAgeKeyBootstrap.darwinUserKeyFile} \
        ${cfg.package}/bin/attic-leaf-sign --activation; then
        echo "[attic-leaf] FAILED at activation — run attic-leaf-sign by hand" >&2
      fi
    '';
  };
}
