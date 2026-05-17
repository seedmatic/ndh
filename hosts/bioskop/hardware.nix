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
}
