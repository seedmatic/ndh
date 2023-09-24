{
  config,
  pkgs,
  ...
}: {
  services = {
    keybase = {
      enable = true;
    };

    kbfs = {
      enable = true;
      # FIXME /keybase needs to be owned by user
      mountPoint = "/keybase";
      extraFlags = ["-label kbfs"];
    };
  };
}
