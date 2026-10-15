{
  config,
  lib,
  pkgs,
  catalog,
  ...
}:
# The Incus cluster certificate on the seat: the one definition of incus-cluster-cert-renew, on the
# operator's PATH, and run by this host's activation when it holds the TLS authority.
#
# ⚠️ At activation the TLS authority's signing slot is used AUTOMATICALLY, as the operator (sudo -u),
# whenever a switch finds the cluster serving a certificate the fleet root did not issue or one that
# lacks a fleet name — not on a date. The operator launches the switch, so it stays a gesture; the
# operator's sops identity decrypts keys.yaml, the operator's ssh identity reaches the members.
let
  cfg = config.ndh.incusClusterCert;
  user = config.profile.user.name;
in
{
  options.ndh.incusClusterCert = {
    package = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = import ../.common.d/incus-cluster-cert.d/package.nix {
        inherit pkgs lib;
        netplan = catalog.netplan;
        operatorIdentity = {
          inherit user;
          keyFile = config.sshPaths.privKeyFile;
          certFile = config.sshPaths.userCertPublic;
        };
      };
      description = "incus-cluster-cert-renew, built for this seat's operator identity.";
    };
    atActivation = lib.mkEnableOption "renewing the Incus cluster certificate at activation (the seat holding the TLS authority)";
  };

  config = lib.mkIf cfg.atActivation {
    environment.systemPackages = [ cfg.package ];
    system.activationScripts.postActivation.text = lib.mkOrder config.ndh.darwin.postActivationOrder.incusClusterCert ''
      # A failure here is loud but does not stop the rest of the activation: the cluster may be down.
      if ! /usr/bin/sudo -u ${lib.escapeShellArg user} -H \
        SOPS_AGE_KEY_FILE=${lib.escapeShellArg config.ndh.sopsAgeKeyBootstrap.darwinUserKeyFile} \
        ${cfg.package}/bin/incus-cluster-cert-renew --activation; then
        echo "[incus-cluster-cert] FAILED at activation — run incus-cluster-cert-renew by hand" >&2
      fi
    '';
  };
}
