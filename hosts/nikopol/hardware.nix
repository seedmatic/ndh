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
}
