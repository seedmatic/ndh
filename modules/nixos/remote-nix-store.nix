# Remote Nix store and daemon configuration for Lima/vz VMs (@codebase)
# This module disables the local nix-daemon, mounts the host's /nix/store using virtiofs,
# and configures Nix to use a remote daemon.

{ config, lib, ... }:
{
  options = { };

  config = {
    services.nix-daemon.enable = false; # Do not run local daemon

    /**
      Mount /nix/store from the host using virtiofs (for Lima/vz VMs).
      This allows the VM to use the host's Nix store and remote daemon.
    */
    fileSystems."/nix/store" = {
      device = "store"; # This label must match the virtiofs share name in your Lima config
      fsType = "virtiofs";
      options = [ ];
    };

    # Optionally mount /nix/var/nix/db and /nix/var/nix/daemon-socket if needed
    # fileSystems."/nix/var/nix/db" = { ... };
    # fileSystems."/nix/var/nix/daemon-socket" = { ... };

    nix.settings = {
      # Use a remote daemon (adjust to your setup)
      build-remote = "ssh-ng://user@host";
      # Or, for a remote Unix socket:
      # build-remote = "unix:///run/nix/remote-daemon.sock";
      # Add any other Nix settings as needed
    };
  };
}
