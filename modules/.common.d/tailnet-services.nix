# Tailscale SERVICES delivery, platform-agnostic.  Renders the declarative
# service-configuration file for THIS host from `catalog.netplan.tailnets.saas.services`
# and exposes it plus the command that applies it; each platform module owns the
# activation (a systemd oneshot on NixOS, postActivation on darwin) because the
# rendering is shared but the trigger is not.
#
# Why a file and not flags: there is no `--advertise-services` preference to set —
# `AdvertiseServices` is a pref that `tailscale serve` writes as a side effect.  The
# vendor's declarative path is `serve set-config <file>` / `get-config`, which exists
# to "declaratively set configuration for a service host".  That is the whole reason
# this chantier fits a nix-managed fleet at all.
#
# Why services rather than subnet routes, in one line: a service's virtual IP is
# accepted by every client REGARDLESS of `--accept-routes`, so nothing installs a
# route — see catalog.netplan.tailnets.saas.services and
# docs/network-topology-c4.adoc#authorisation.
{
  config,
  lib,
  pkgs,
  ndh ? null,
  ...
}:
let
  cfg = config.networking.tailnet;

  allServices = lib.attrByPath [
    "context"
    "catalog"
    "netplan"
    "tailnet"
    "services"
  ] { } ndh;

  # A host advertises a service when the catalog names it among the advertisers, under
  # the SAME name it registers with (`networking.tailnet.hostname`, defaulting to
  # `networking.hostName` on both platforms).  Matching on the registration name is not
  # incidental: a device's machine name is fixed at registration, so this is the only
  # identifier that is guaranteed to agree with what the control plane sees.
  mine = lib.filterAttrs (_: svc: lib.elem cfg.hostname svc.advertisers) allServices;

  serviceConfig = {
    version = "0.0.1";
    services = lib.mapAttrs' (
      name: svc:
      lib.nameValuePair "svc:${name}" {
        inherit (svc) endpoints;
        advertised = true;
      }
    ) mine;
  };

  configFile = pkgs.writeText "tailnet-services-${cfg.hostname}.json" (builtins.toJSON serviceConfig);
in
{
  options.ndh.tailnetServices = {
    configFile = lib.mkOption {
      type = lib.types.path;
      readOnly = true;
      internal = true;
      description = "Rendered `tailscale serve set-config` document for this host.";
    };
    applyCommand = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      internal = true;
      description = "Idempotent command that reconciles this host's advertised services.";
    };
    names = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      internal = true;
      description = "Service names this host advertises (diagnostics only).";
    };
  };

  config.ndh.tailnetServices = {
    inherit configFile;
    names = builtins.attrNames mine;
    # `--all` is what makes this a reconcile rather than an append: it overwrites every
    # service this node hosts, so a service REMOVED from the catalog is withdrawn by the
    # next activation instead of lingering.  The document is therefore rendered and
    # applied even when empty — an empty `services` map is how a host stops advertising.
    # ⚠️ `--all` MUST precede the filename.  The CLI parses flags only up to the first
    # positional argument, so `set-config <file> --all` makes `--all` a second positional
    # and fails with the misleading "must specify filename" — while the usage line prints
    # `set-config <file> [--all]`, which is the order that does NOT work.  Measured
    # 2026-09-27: the activation ran, swallowed that error by design, and bioskop silently
    # advertised nothing while all four services existed in the tailnet.
    applyCommand = "${lib.getExe' pkgs.tailscale "tailscale"} serve set-config --all ${configFile}";
  };
}
