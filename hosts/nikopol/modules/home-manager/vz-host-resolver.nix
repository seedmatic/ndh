# Per-host home-manager module: ships the `vz.nikopol` SSH alias and
# its bare-metal-IP resolver into the operator's nix-profile.  Only
# imported on the nikopol VM (see hosts/nikopol/modules/darwin/
# vz-host-resolver.nix's hm.imports).
#
# Why this lives in modules/home-manager rather than modules/darwin:
# `home.packages` here lands the resolver in the operator's user
# nix-profile, which is where SSH's ProxyCommand expects to find it.
# The Darwin-side module bridges via `hm.imports` because the host-
# scope guard (config.profile.host.hostName == "nikopol") needs to
# fire from the system-config evaluation.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  # Bare metal's Wi-Fi MAC on the HOME SSID.  This is the macOS "Private Wi-Fi
  # Address = Fixed" value (locally-administered — the `4a:` LA bit is set), which
  # is stable PER-SSID as long as the setting stays Fixed.  It silently stopped
  # resolving once when Private Wi-Fi was flipped off Fixed (macOS then presented
  # the real HW MAC `84:2f:57:d4:36:be`, so the ARP lookup for this value found
  # nothing); re-pinning the SSID to Fixed restores it.  Caveats: "Fixed" is
  # PER-SSID, so this only matches home — on another network set Private Wi-Fi
  # Off (→ HW MAC, same everywhere) or record that SSID's fixed MAC.  mDNS is NOT
  # a fallback: the corp Mac blocks Bonjour by policy.
  bareMetalMac = "4a:04:df:ff:a8:de";

  # Bin name + bin path on disk.  This fleet runs nix-darwin with
  # `home-manager.useUserPackages = true`, which routes home.packages
  # through `users.users.<user>.packages` and lands them at
  # /etc/profiles/per-user/<user>/bin/.  That's a stable, OS-managed
  # directory on PATH — the resolver lives there, not in
  # ~/.nix-profile/bin/ (which on this fleet is the legacy nix-env
  # profile and contains only zsh).
  #
  # The path is host-stable: any host with this resolver in
  # home.packages exposes it at the same /etc/profiles path.  The
  # bioskop-side ProxyCommand in modules/home-manager/ssh-tailnet-hosts.nix
  # references the bare command name and relies on PATH expansion in
  # the remote shell — that works because nikopol's interactive zsh
  # has /etc/profiles/per-user/nxmatic/bin on PATH.
  binName = "nikopol-vz-host-resolve-ip";

  # writeShellApplication's curated PATH is pkgs-only; the resolver
  # uses macOS-system tools (ping, arp, ifconfig).  Prepend /sbin and
  # /usr/sbin to PATH in the script body so writeShellApplication's
  # strict PATH wrapper finds them.  runtimeInputs = [ gawk ] keeps
  # awk's behaviour stable across Darwin BSD-awk variants.
  resolverPkg = pkgs.writeShellApplication {
    name = binName;
    runtimeInputs = with pkgs; [ gawk ];
    text = ''
      # macOS network tools live outside nixpkgs.
      PATH="/sbin:/usr/sbin:$PATH"
    ''
    + builtins.readFile (
      pkgs.replaceVars ./vz-host-resolver.d/resolve-ip.sh {
        bareMetalMac = bareMetalMac;
      }
    );
  };
in
{
  # Lands the resolver at ~/.nix-profile/bin/<binName>, store-pinned
  # via the package, atomically swapped per home-manager generation.
  home.packages = [ resolverPkg ];

  # SSH alias: `vz.nikopol` resolves to whatever IP the bare metal
  # has on the current Wi-Fi network.  ProxyCommand pipes
  # stdin/stdout through `nc` to the resolved (host, 22), the
  # standard way to express "open a TCP connection to a dynamically-
  # resolved address" in OpenSSH config (mirrors the tart-config.nix
  # idiom for tart-launched VMs).
  #
  # User is `stephane.lacoin` (the corp account on the bare metal)
  # and the key is the operator's rdp-host private — the matching
  # public is already in that account's authorized_keys.
  programs.ssh.settings."vz.nikopol" = {
    User = "stephane.lacoin";
    IdentityFile = config.sshPaths.privKeyFile;
    IdentitiesOnly = true;
    ProxyCommand = ''sh -c 'nc "$(${binName})" 22' '';
  };
}
