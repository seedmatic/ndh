{
  pkgs,
  ...
}: {
  environment = {
    systemPackages = with pkgs;
      [ direnv ];
  };
  
  services = {
    lorri.enable = true;
  };
}
