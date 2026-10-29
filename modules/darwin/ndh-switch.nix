{
  config,
  lib,
  pkgs,
  catalog,
  ndh,
  self,
  ...
}:
# ndh-switch on the operator seat's PATH: the one switch verb the sessions may run (the managed list denies the raw
# rebuilds), so 🎛️ operations switches the fleet by a pushed, merged revision while the operator is away.
let
  cfg = config.ndh.ndhSwitch;
in
{
  options.ndh.ndhSwitch = {
    enable = lib.mkEnableOption "ndh-switch, the sessions' switch verb, on this operator seat";
    package = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = import ../.common.d/ndh-switch.d/package.nix {
        inherit pkgs catalog;
        seat = config.networking.hostName;
      };
      description = "ndh-switch, built for this seat: it refuses to run from any other.";
    };
    fleetSwitch = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = import ../.common.d/fleet-switch.d/package.nix {
        inherit pkgs;
        ndhSwitch = cfg.package;
      };
      description = "fleet-switch, the ordered loop over this seat's ndh-switch.";
    };
    ops = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = import ../.common.d/ops-queue.d/package.nix {
        inherit pkgs catalog ndh;
        keys = config.ndh.keysYaml.allSlots;
        keysReconcile = "${cfg.keysReconcile}/bin/keys-reconcile";
        ndhOps = "${cfg.ndhOps}/bin/ndh-ops";
      };
      description = "ops, the operator's entry point to the fabric's pending steps, its queue derived from keys.yaml.";
    };
    sshKeysRenew = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = import ../.common.d/ssh-keys-renew.d/package.nix {
        inherit pkgs ndh;
        inherit (catalog) netplan;
      };
      description = "ssh-keys-renew, built for this seat: one of ndh-ops's tools, and the flake's app.";
    };
    sshKeysCertify = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = import ../.common.d/ssh-keys-certify.d/package.nix {
        inherit pkgs ndh;
        hostCertificates = self.fleetHostCertificates;
      };
      description = "ssh-keys-certify, built for this seat: one of ndh-ops's tools, and the flake's app.";
    };
    viewerKubeconfig = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = import ../.common.d/viewer-kubeconfig.d/package.nix { inherit pkgs; };
      description = "viewer-kubeconfig: the sessions' read-only kubeconfig, collected from the operator's; one of ndh-ops's tools.";
    };
    # The armed delegation's runner, installed by the switch: its tools are this seat's own packages, by store path.
    ndhOps = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = import ../.common.d/ndh-ops.d/package.nix {
        inherit pkgs;
        tools = {
          ssh-keys-certify = "${cfg.sshKeysCertify}/bin/ssh-keys-certify";
          ssh-keys-renew = "${cfg.sshKeysRenew}/bin/ssh-keys-renew";
          incus-cluster-cert-renew = "${config.ndh.incusClusterCert.package}/bin/incus-cluster-cert-renew";
          ndh-keyring = "${config.ndh.keyring.package}/bin/ndh-keyring";
          keys-reconcile = "${cfg.keysReconcile}/bin/keys-reconcile";
          fleet-switch = "${cfg.fleetSwitch}/bin/fleet-switch";
          viewer-kubeconfig = "${cfg.viewerKubeconfig}/bin/viewer-kubeconfig";
        };
      };
      description = "ndh-ops, on this seat's PATH: runs one of the operator's tools on the delegation they armed.";
    };
    keysReconcile = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = import ../.common.d/keys-reconcile.d/package.nix {
        inherit pkgs catalog ndh;
        keys = config.ndh.keysYaml.allSlots;
        # The revision this seat's closure is built from: keys-reconcile works on it alone, and refuses it unpushed.
        revision = config.system.configurationRevision or "";
        inherit (cfg.package) machines;
        inherit (config.ndh.hostKey) publishDir;
        hostNames = self.fleetHostNamesByMachine;
        atticCaches =
          lib.concatMap
            (
              g:
              let
                a = g.config.ndh.atticCache;
              in
              lib.optional a.enable {
                machine = g.config.networking.hostName;
                metalspace = if a.metalspace != null then a.metalspace else lib.removePrefix "attic." a.fqdn;
                inherit (a) fqdn;
                dir = (import ../nixos/attic-cache.d/paths.nix).publishDir;
              }
            )
            (map (m: self.nixosConfigurations.${m.name}) (lib.filter (m: m.kind == "nixos") catalog.machines));
        keysJsonTool = "${
          import ../.common.d/keys-yaml.d/json-tool.nix { inherit pkgs; }
        }/bin/ndh-keys-json";
        inherit (import ../.common.d/ndh-ops.d/paths.nix) delegation;
        # A key a machine still uses: its sshPaths.keyName, or a key whose public is in an authorized_keys it renders.
        inUseKeys =
          let
            keys = config.ndh.keysYaml.keys;
            configOf =
              m:
              if m.name == config.networking.hostName then
                config
              else if m.kind == "nixos" then
                self.nixosConfigurations.${m.name}.config
              else
                self.darwinConfigurations.${m.name}.config;
            authorizedText =
              c:
              lib.concatStringsSep "\n" (
                lib.concatMap (u: u.openssh.authorizedKeys.keys or [ ]) (lib.attrValues (c.users.users or { }))
                ++ lib.mapAttrsToList (_: e: e.text or "") (
                  lib.filterAttrs (n: _: lib.hasPrefix "ssh/nix_authorized_keys.d/" n) (c.environment.etc or { })
                )
              );
            usedBy =
              c:
              let
                text = authorizedText c;
              in
              [ c.sshPaths.keyName ]
              ++ lib.filter (
                k:
                lib.any (s: (s.public or null) != null && lib.hasInfix s.public text) (
                  lib.attrValues (keys.${k}.slots or { })
                )
              ) (lib.attrNames keys);
          in
          lib.unique (lib.concatMap (m: usedBy (configOf m)) catalog.machines);
      };
      description = "keys-reconcile, the window step: its revision, batch and machines are this closure's.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      cfg.package
      cfg.fleetSwitch
      cfg.ops
      cfg.ndhOps
      cfg.keysReconcile
    ];
  };
}
