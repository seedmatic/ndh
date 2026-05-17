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
# Bioskop reaches the bare metal via this VM by chaining: bioskop →
# nikopol VM (tailnet) → bare metal (local segment).  Bioskop's SSH
# config carries `Host vz.nikopol  ProxyJump nikopol`; the rest is
# delegated to this VM's resolver.
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

  resolveScript = ndh.store.installScript {
    name = "nikopol-vz-host-resolve-ip.sh";
    source = pkgs.replaceVars ./vz-host-resolver.d/resolve-ip.sh {
      nixBashTrampoline = ndh.context.nixBashTrampoline;
      bareMetalMac = bareMetalMac;
    };
    preferLocalBuild = true;
    allowSubstitutes = false;
    mode = "0755";
  };

  user = config.profile.user;
  userHome = toString user.home;
  resolveScriptInstallPath = "${userHome}/.local/bin/nikopol-vz-host-resolve-ip";
in
{
  config = lib.mkIf (config.profile.host.hostName == "nikopol") {
    # Install the resolver into a stable in-home path the SSH config
    # can reference verbatim.  Done via activation rather than a
    # home-manager file so the path is the same regardless of which
    # generation is active.
    system.activationScripts.postActivation.text = lib.mkAfter ''
      install -m 0755 -D ${resolveScript} ${lib.escapeShellArg resolveScriptInstallPath}
    '';

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
      proxyCommand = ''sh -c 'nc "$(${resolveScriptInstallPath})" 22' '';
    };
  };
}
