# Single source of truth for serial console configuration.
# Configures kernel console parameters for headless/serial access via screen/socat.
#
# QEMU/Tart VZ guests use virtio-serial (hvc0) as primary console with video (tty0)
# as fallback. The last console= parameter wins as /dev/console default.
#
# Import this module in any NixOS config that needs serial console access.
{ lib, ... }:
{
  # Serial console kernel parameters
  # hvc0 = first virtio-serial port (for QEMU/Tart VZ guests)
  # tty0 = video console (fallback)
  boot.kernelParams = [
    "console=tty0"
    "console=hvc0"
  ];

  # Auto-login root on all gettys for emergency/bringup access
  services.getty.autologinUser = lib.mkDefault "root";
}
