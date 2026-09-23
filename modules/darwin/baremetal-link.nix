{
  config,
  lib,
  pkgs,
  ndh,
  self,
  ...
}:
# The baremetal-link /30 alias for a vz-host that IS a nix-darwin machine.
#
# bioskop is its own bare-metal: `vzhost.bioskop` and this darwinConfiguration are the same
# Mac.  nikopol's vz-host is not — it is the JAMF-managed corp Mac *hosting* the `nikopol`
# VM, which runs neither nix nor tailscale, so it is fed the same script over ssh by
# `nix run .#nikopol-baremetal-link-deploy` (pkgs/baremetal-link.d/deploy.sh).  The catalog
# names that difference once, as `vzHostKind`, and both paths read it.
#
# Same artifact, two deliveries — deliberately NOT a second implementation.  We run the
# rendered `<host>-baremetal-link-install` package, exactly what the ssh path pipes to its
# target, so the two hosts cannot drift.  The script itself skips the two pieces nix-darwin
# already owns here (the scoped resolver, the guest nudge).
#
# Why still a LaunchDaemon rather than a plain activation step: macOS drops interface
# aliases when the link re-associates, so the alias has to be re-applied on every
# SystemConfiguration change — which is what the daemon's WatchPaths does.  Activation
# installs and loads it; the daemon keeps it true afterwards.
#
# See catalog/default.nix (netplan.baremetal.<host>.vzHostKind) and
# docs/network-topology-c4.adoc.
let
  hostProfile = config.profile.host;
  effectiveHostName =
    if (hostProfile ? hostAlias && hostProfile.hostAlias != null && hostProfile.hostAlias != "") then
      hostProfile.hostAlias
    else
      hostProfile.hostName;

  bm = ndh.context.catalog.netplan.baremetal.${effectiveHostName} or null;
  enabled = bm != null && bm ? linkCidr && bm.vzHostKind == "nix-managed";

  installScript =
    self.packages.${pkgs.stdenv.hostPlatform.system}."${effectiveHostName}-baremetal-link-install";
in
{
  # `postActivation`, NOT a new activationScripts key.  Unlike NixOS, nix-darwin concatenates
  # a FIXED set of script names into `system.activationScripts.script`; an arbitrary key still
  # type-checks and still shows up in the attrset, but is never run — a silent no-op (measured:
  # the aggregated script contained zero references to it).  `postActivation` also runs after
  # `etc`, so baremetal-resolvers.nix has already landed /etc/resolver/<domain> by the time the
  # daemon starts routing the segment that file points at.
  system.activationScripts.postActivation.text = lib.mkIf enabled (
    lib.mkAfter ''
      echo "[baremetal-link] installing ${bm.vzHostAddress}/${lib.last (lib.splitString "/" bm.linkCidr)} on service '${
        (import (../../hosts + "/${effectiveHostName}/hardware.nix")).vmBridgeService
      }'" >&2
      ${pkgs.bash}/bin/bash ${installScript}
    ''
  );
}
