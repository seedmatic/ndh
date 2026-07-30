{
  config,
  lib,
  pkgs,
  worktreePath,
  ...
}:
# Provider-agnostic operator identity for Incus: provisions the user's
# ~/.config/incus so any node's `incus` CLI (and the seed-master Pulumi provider,
# which rides this same config via `configDir(~/.config/incus)` +
# generateClientCertificates(false)) authenticates to the cluster's Incus server.
#
# One module, every node, one account: each node derives its remote from its own
# VM identity (`<host>-nixos`) and keeps a per-node operator identity
# `nxmatic@<host>` — matching the reference host. The declarative shape is
# identical across nodes; only the trust step is topology-dependent (see the
# script): a node running the daemon locally mints over its unix socket, a Mac
# operator mints over SSH on the guest.
let
  specialArgs =
    if config ? _module && config._module ? specialArgs then config._module.specialArgs else { };
  nixBashTrampoline =
    if
      specialArgs ? ndh && specialArgs.ndh ? context && specialArgs.ndh.context ? nixBashTrampoline
    then
      "${specialArgs.ndh.context.nixBashTrampoline}"
    else
      "${worktreePath.of "modules/.common.d/shell.d/nix-bash-trampoline.sh"}";
  profile = config._module.specialArgs.profile;
  userName = profile.user.name;
  hostProfile = profile.host or { };
  hostName =
    if (hostProfile ? hostAlias && hostProfile.hostAlias != null && hostProfile.hostAlias != "") then
      hostProfile.hostAlias
    else
      hostProfile.hostName;
  cfg = config.ndh.incusRemote;
  # Incus is Linux-only in nixpkgs; only the client build cross-compiles to
  # Darwin — the same reason rke2lab's flake mirrors `incus.passthru.client`.
  incusClientBin = "${pkgs.incus.passthru.client}/bin/incus";
  loggerTag = "home-manager.activationScripts.${userName}.incusRemote";
in
{
  options.ndh.incusRemote = {
    enable = lib.mkEnableOption "operator ~/.config/incus provisioning (client identity + remote trust)";
    remoteName = lib.mkOption {
      type = lib.types.str;
      default = "${hostName}-nixos";
      description = "Name of the Incus remote (the cluster's NixOS server), derived from the VM host identity.";
    };
    remoteAddress = lib.mkOption {
      type = lib.types.str;
      default = "https://${hostName}-nixos.local:8443";
      description = "HTTPS address of the Incus server. Overridable for tailnet/bare-hostname resolution.";
    };
    trustHost = lib.mkOption {
      type = lib.types.str;
      default = "${hostName}-nixos.local";
      description = "SSH host on which to mint the trust token when this node has no local Incus daemon socket.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.activation.incusRemote =
      let
        ensureScript = pkgs.replaceVars ./incus-remote.d/ensure-incus-operator-remote.sh {
          nixBashTrampoline = nixBashTrampoline;
          loggerTag = loggerTag;
          incus = incusClientBin;
          remoteName = cfg.remoteName;
          remoteAddress = cfg.remoteAddress;
          trustHost = cfg.trustHost;
        };
      in
      lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        ${pkgs.bash}/bin/bash ${ensureScript}
      '';
  };
}
