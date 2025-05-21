{pkgs, ...}: let
  # Create a derivation for setting up QEMU firmware
  dollar = "$";
in {
  # Add necessary packages to system environment
  environment.systemPackages = with pkgs; [
    devcontainer
  ];

  # Additional configuration options can be added here as needed
}
