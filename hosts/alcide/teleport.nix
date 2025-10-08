{ config, lib, pkgs, ... }:

{
  # Only install the Teleport client package
  environment.systemPackages = with pkgs; [
    teleport
  ];
  
  # Disable the Teleport service on alcide
  services.teleport.enable = false;
  
  # Create a configuration file for tsh (Teleport client)
  environment.etc."teleport/tsh_config.yaml".text = ''
    teleport:
      proxy_server: bioskop.mammoth-skate.ts.net:3080
      auth_server: bioskop.mammoth-skate.ts.net:3025
  '';
  
  # Create a handy alias for easier access
  environment.shellAliases = {
    tsh = "tsh --proxy=bioskop.mammoth-skate.ts.net:3080";
  };
}
