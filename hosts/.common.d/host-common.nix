{
  hostProfile,
  darwinProfile,
  headscaleServerUrl,
  headscaleEnableSSH ? true,
  forceRemoteBuilds ? null,
  preferredBuilderHosts ? null,
  bioskopCachePublicKey ? "bioskop-cache:H6oZXzgzujE4+saXVe6LDfzBRUUVCgPYYTFLoxK7IuE=",
}:
{
  lib,
  options,
  ...
}:
let
  hasHeadscaleOption = options ? networking && options.networking ? headscale;
in
{
  imports = [ ../../profiles/committed.nix ];

  config = {
    profile = {
      host = {
        hostName = lib.mkDefault hostProfile.hostName;
        tailnet = hostProfile.tailnet;
      }
      // (lib.optionalAttrs (hostProfile ? hostAlias) {
        hostAlias = lib.mkDefault hostProfile.hostAlias;
      })
      // (lib.optionalAttrs (forceRemoteBuilds != null) {
        forceRemoteBuilds = forceRemoteBuilds;
      })
      // (lib.optionalAttrs (preferredBuilderHosts != null) {
        preferredBuilderHosts = preferredBuilderHosts;
      });

      darwin = darwinProfile;
    };

    # Enable cross-host builders so ssh_config.d drop-ins are installed
    services.crossHostBuilders.enable = true;

    # Trust bioskop local signing key on non-bioskop hosts for nix copy --from ssh-ng://...@bioskop
    nix.settings.extra-trusted-public-keys = lib.mkIf (hostProfile.hostName != "bioskop") [
      bioskopCachePublicKey
    ];
  }
  // (lib.optionalAttrs hasHeadscaleOption {
    networking.headscale = {
      enable = true;
      serverUrl = headscaleServerUrl;
      enableSSH = headscaleEnableSSH;
    };
  });
}
