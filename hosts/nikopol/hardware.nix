{
  model = "Apple M4 Pro";
  ramGiB = 48;
  cpuCores = 14; # 10 performance + 4 efficiency

  # Physical network adapters present on this machine.
  # Names must match macOS service names exactly (networksetup -listallnetworkservices).
  knownNetworkServices = [
    "Wi-Fi"
    "Thunderbolt Ethernet"
  ];

  # The adapter this machine's vz guest is BRIDGED onto — see the comment in
  # hosts/bioskop/hardware.nix for why this is single-sourced and why it is a service
  # name rather than an `enX` device.
  vmBridgeService = "Wi-Fi";
}
