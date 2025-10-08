{ config, lib, pkgs, ... }:

{
  services.teleport = {
    # Only override what's different from the Darwin module defaults
    acme = {
      enabled = true;
      email = config.profile.email;  # Uses the email from the profile
    };
    
    # Enable debug logging initially, can be reduced later
    logLevel = "DEBUG";
    
    # Ensure the proxy service is enabled with ACME
    proxyService = true;
  };
  
  # Add teleport to the admin group
  users.groups.admin.members = [ "teleport" ];
  
  # On macOS, you'll need to manually configure the firewall to allow these ports:
  # - 3022: SSH service
  # - 3025: Auth service
  # - 3080: Web UI
  # 
  # You can use the built-in pf firewall or a third-party firewall application.
  # For example, to allow these ports using pf, you would run:
  # sudo pfctl -f /etc/pf.conf
  # echo "pass in proto tcp from any to any port { 3022, 3025, 3080 } keep state" | sudo pfctl -f -
}
