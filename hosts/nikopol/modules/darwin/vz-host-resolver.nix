# Per-host module that wires the `vz.nikopol` SSH alias on the
# nikopol Tart VM, reaching the bare-metal MacBook Pro that hosts the
# VM via the local L2 segment they share.
#
# Why this lives here, not in the shared `modules/darwin/`:
# the bare-metal Mac is uniquely tied to nikopol-the-VM (it's the
# host running the VM).  Bioskop has no equivalent — it's its own
# bare metal, no separate VZ host above it.  The MAC and the
# resolver only make sense from this VM's perspective.
#
# How it works:
#   - The bare metal keeps Private Wi-Fi: Off, so peers see the same
#     hardware MAC on every Wi-Fi network.  We bake that MAC into
#     the resolver script at build time.
#   - At connect time, `arp -an` on this VM lists the local L2
#     peers; the resolver matches by MAC and prints the current IP.
#   - The SSH alias `vz.nikopol` uses `ProxyCommand=… nc <ip> 22`
#     to route the connection through the resolved IP.  Auth is the
#     operator's existing rdp-host private key (via the catalog user
#     `nxmatic`'s key, whose public is in stephane.lacoin@bare-metal's
#     authorized_keys).
#
# Bioskop reaches the bare metal via this VM by chaining a
# `ProxyCommand ssh nikopol-ts "nc $(<resolver>) 22"`; the resolver
# is on the VM (this module) and the bioskop-side alias references
# its `/run/current-system/sw/bin/...` path from
# modules/home-manager/ssh-tailnet-hosts.nix.
{
  config,
  lib,
  pkgs,
  ndh,
  ...
}:
let
  # Bare metal's stable hardware MAC (Private Wi-Fi: Off).  Captured
  # from `ifconfig en0 | grep ether` on the bare metal; same value
  # on every network it joins.  If the MAC ever changes (hardware
  # swap, Private Wi-Fi flipped to Fixed/Rotating), update here.
  bareMetalMac = "52:2d:10:fa:5a:1c";

  # The resolver is consumed only by the operator's SSH client (here
  # via the matchBlock below, on bioskop via vzAliasForBioskopSide
  # in modules/home-manager/ssh-tailnet-hosts.nix).  That's user-scope,
  # so the script ships via home-manager's `home.packages` and lives
  # at ~/.nix-profile/bin/<binName> for the operator — no
  # system-package install, no activation copy, no root ownership.
  #
  # Bin name is mirrored in vzAliasForBioskopSide; if you rename here,
  # rename there too.  The `~/` in binPath expands on whichever shell
  # sees it — the operator's local shell here, the remote (nikopol)
  # shell when invoked from bioskop's chained ProxyCommand.
  binName = "nikopol-vz-host-resolve-ip";
  binPath = "~/.nix-profile/bin/${binName}";

  # writeShellApplication wraps the script with a curated PATH and
  # runs shellcheck at build time.  The token-substituted source
  # lives in $out/bin/<binName>.
  # writeShellApplication's curated PATH is pkgs-only, but the
  # resolver uses `ping`, `arp`, `ifconfig`, and `awk` — three of
  # which are macOS-system tools (not in nixpkgs in any Darwin-
  # buildable form).  Add /sbin and /usr/sbin to PATH explicitly via
  # the script body so writeShellApplication's strict-PATH wrapper
  # finds them; runtimeInputs lists only the genuinely Nix-provided
  # `gawk` (over the BSD awk which differs subtly).
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
  config = lib.mkIf (config.profile.host.hostName == "nikopol") {
    # Install the resolver into the operator's user nix-profile via
    # home-manager.  Lands at ~/.nix-profile/bin/<binName> — a
    # store-pinned path that updates atomically per generation.  No
    # activation copy, no root ownership.  Scope matches the
    # consumer (the operator's SSH client) rather than the system.
    hm.home.packages = [ resolverPkg ];

    # SSH alias: `vz.nikopol` resolves to whatever IP the bare metal
    # has on the current Wi-Fi network.  ProxyCommand pipes
    # stdin/stdout through `nc` to the resolved (host, 22), which is
    # the standard way to express "open a TCP connection to a
    # dynamically-resolved address" in OpenSSH config (mirrors the
    # tart-config.nix idiom for tart-launched VMs).
    #
    # User is `stephane.lacoin` (the corp account on the bare metal)
    # and the key is the operator's rdp-host private — the matching
    # public is already in that account's authorized_keys.
    hm.programs.ssh.matchBlocks."vz.nikopol" = {
      user = "stephane.lacoin";
      identityFile = "~/.local/var/run/secrets/ssh-keys/rdp-host";
      identitiesOnly = true;
      proxyCommand = ''sh -c 'nc "$(${binPath})" 22' '';
    };
  };
}
