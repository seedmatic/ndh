{ hostProfile, darwinProfile }:
{
  config,
  ...
}:
{
  imports = [
    (import ../host-common.nix {
      inherit hostProfile darwinProfile;
      headscaleServerUrl = "http://192.168.5.10:8080";
    })
    # Teleport removed - using Headscale for internal network
  ];
  config = {
    # Enable rescue tooling for this host when needed (default is off)
    # rescue.enable = true;

    # Sign locally produced store paths so peer hosts can trust nix copy --from ssh-ng://bioskop
    nix.settings.trusted-users = [
      "builder"
    ];
  };
}
