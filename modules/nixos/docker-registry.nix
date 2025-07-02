{ config, pkgs, ... }: {
  services.dockerRegistry = {
    enable = true;
    listenAddress = "127.0.0.1";
  };
}
