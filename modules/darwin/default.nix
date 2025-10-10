{ profile, config, lib, pkgs, self, ... }: {
  imports = [
    ../common
    ./preferences.nix
    ./security.nix
    ./core.nix
    ./dnsmasq.nix
    ./headscale-client.nix
    ./lima-config.nix
    ./linux-builder.nix
    ./distributed-builds.nix
    ./podman-remote-client.nix
    ./raycast.nix
    ./socket_vmnet.nix
    ./openssh.nix
    # Teleport removed - using Headscale/Tailscale SSH
    # Inline module replaced with file import for Home Manager extension
    ./extend-hm-imports.nix
    # Added GitHub MCP proxy module
    ./github-mcp-proxy.nix
  ];
}
