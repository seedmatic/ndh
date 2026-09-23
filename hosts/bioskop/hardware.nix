{
  model = "Apple M3 Max";
  ramGiB = 64;
  cpuCores = 14; # 10 performance + 4 efficiency

  # Physical network adapters present on this machine.
  # Names must match macOS service names exactly (networksetup -listallnetworkservices).
  knownNetworkServices = [
    "Thunderbolt Ethernet Slot 1"
    "Ethernet"
    "USB 10/100/1000 LAN"
    "Wi-Fi"
    "Thunderbolt Bridge"
  ];

  # The adapter this machine's vz guest is BRIDGED onto — one of the services above.
  # Single source for two consumers that must agree or the link silently breaks:
  # `tart.configGenerator.vmRunBridgeInterface` (darwin.nix) and the baremetal-link
  # /30 alias (flake.nix `baremetalLinkVars`). They must agree because the /30's far
  # end is the guest's own lan-br: alias the wrong adapter and the two ends no longer
  # share an L2. Declared as a SERVICE name, never as `enX` — device numbering shifts
  # with adapter enumeration, service names don't; consumers resolve it at runtime.
  vmBridgeService = "Thunderbolt Ethernet Slot 1";
}
