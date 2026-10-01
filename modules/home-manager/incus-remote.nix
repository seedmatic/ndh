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
      "${worktreePath.runtimeFile "modules/.common.d/shell.d/nix-bash-trampoline.sh"}";
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
      default = "https://nixos.${hostName}:8443";
      description = ''
        HTTPS address of the Incus server — `nixos.<host>`, the name WE declare, served by that
        bare-metal's own dnsmasq in its `.<host>` zone and carried in the listener certificate's SAN.

        ⚠️ It was the bare `<host>-nixos`, on the stated ground that MagicDNS answers it instantly.
        Measured 2026-10-01 with getaddrinfo — what the incus client actually calls — that is not what
        happens: a single-label name gets the search list applied, so `lan` answers FIRST and
        `bioskop-nixos` resolves to 192.168.1.130. The remote then points at whatever the home LAN
        calls that name, which is why the URL had to be repaired by hand with `incus remote set-urls`.
        `.local` is still rightly avoided (mDNS stalls ~5s on macOS); the fix is a name we own, not
        another name we do not.
      '';
    };
    trustHost = lib.mkOption {
      type = lib.types.str;
      default = "nixos.${hostName}";
      description = ''
        SSH host on which to mint the trust token when this node has no local Incus daemon socket.
        The same name as the remote address, for the same reason — and it is also the ssh alias ndh
        declares, so one name reaches the daemon and the shell alike.
      '';
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
