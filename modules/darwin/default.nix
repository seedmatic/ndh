{ profile, config, lib, pkgs, self, ... }: {
  imports = [
    ../common
    ./preferences.nix
    ./security.nix
    ./core.nix
    ./dnsmasq.nix
    ./lima-config.nix
    ./linux-builder.nix
    ./distributed-builds.nix
    ./podman-remote-client.nix
    ./raycast.nix
    # ./openssh.nix  # Disabled in favor of Teleport
    ./teleport.nix
    # Inline module replaced with file import for Home Manager extension
    ./extend-hm-imports.nix
    # Added GitHub MCP proxy module
    ./github-mcp-proxy.nix
  ];
}
