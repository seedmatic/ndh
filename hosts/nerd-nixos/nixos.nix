{ ... }:
{
  # Keep this host module intentionally minimal: it represents the shared
  # nerd-nixos baseline used to stamp host-specific disk images.

  bringupObserve = {
    enable = true;
    # macOS VZ Lima vzNAT gateway — Vector aggregator on the host
    upstreamEndpoint = "http://192.168.5.2:9001";
  };
}
