{ config, lib, pkgs, ... }:

{
  # Enable systemd in the initrd (EXPERIMENTAL)
  boot.initrd.systemd = {

    enable = false;

    emergencyAccess = true;

    # Example: Add a custom systemd service to the initrd
    services."hello-initrd" = {
      description = "Say hello from initrd";
      wantedBy = [ "initrd.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.coreutils}/bin/echo 'Hello from initrd systemd!'";
      };
    };
  };

  # boot.plymouth = {
  #   enable = false;
  #   theme = "rings";
  #   themePackages = with pkgs;
  #     [
  #       # By default we would install all themes
  #       (adi1090x-plymouth-themes.override { selected_themes = [ "rings" ]; })
  #     ];
  # };

  # You can add more initrd systemd units here as needed
}
