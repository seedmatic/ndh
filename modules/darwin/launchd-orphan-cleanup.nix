# Remove stale launchd plists left behind by past renames or removed
# modules.  nix-darwin only owns the labels it currently declares; a
# plist that used to be ours but no longer is sits at /Library/LaunchDaemons
# with KeepAlive=true and launchd happily respawns the dead daemon.
#
# This list is curated.  Add entries here when a rename or removal
# leaves an `org.nixos.<x>.plist` (or any other plist whose declaring
# module has been deleted) that the next activation won't manage.
# After a single rebuild + activation, the on-disk plist is gone and
# this hook becomes a no-op (the `[[ -e ]]` guard short-circuits).
{
  ...
}:
let
  # Daemons we used to declare under the nix-darwin default
  # `org.nixos.<key>` label, now relabelled under our own prefix.
  # Each entry is the *legacy* label (no .plist suffix); the
  # activation script computes `/Library/LaunchDaemons/<label>.plist`
  # and runs `launchctl bootout` + `rm`.
  staleLabels = [
    # Renamed to `io.nxmatic.nix-darwin-home.nxmatic-cachix-watch-store`
    "org.nixos.nxmatic-cachix-watch-store"
    # Renamed to `io.nxmatic.nix-darwin-home.static-routes`
    "org.nixos.static-routes"
    # network-bond-wifi-manager: its declaring module was deleted but
    # the on-disk plist sticks around and launchd respawns it.
    "org.nixos.network-bond-wifi-manager"
  ];

  # Plain files (not actual launchd labels) that ended up under
  # /Library/LaunchDaemons/ — or anywhere else — and should just be
  # removed.  E.g. nix-darwin's own backup files, or stale copies of
  # files we used to install via activation scripts before switching
  # to package-managed delivery.
  stalePaths = [
    "/Library/LaunchDaemons/org.nixos.linux-builder.plist~bak"
    # The nikopol vz-host ARP resolver is fully retired (vzhost.nikopol now
    # resolves via split-DNS).  A legacy root-owned copy may still linger
    # in ~/.local/bin/ from the old postActivation `install -m 0755 -D`
    # path — sweep it so it doesn't shadow anything in PATH.
    "/Volumes/user-home/.local/bin/nikopol-vz-host-resolve-ip"
  ];

  cleanupLabelCmd = label: ''
    if [[ -e /Library/LaunchDaemons/${label}.plist ]]; then
      echo "[launchd-orphan] removing stale label ${label}"
      # bootout is idempotent; `|| true` covers the case where the
      # service was already unloaded but the plist file remained.
      launchctl bootout system/${label} 2>/dev/null || true
      rm -f /Library/LaunchDaemons/${label}.plist
    fi
  '';

  cleanupPathCmd = path: ''
    if [[ -e ${path} ]]; then
      echo "[launchd-orphan] removing stale file ${path}"
      rm -f ${path}
    fi
  '';
in
{
  system.activationScripts.postActivation.text = builtins.concatStringsSep "\n" (
    map cleanupLabelCmd staleLabels ++ map cleanupPathCmd stalePaths
  );
}
