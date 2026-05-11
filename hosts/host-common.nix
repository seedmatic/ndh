{
  hostProfile,
  darwinProfile,
  headscaleServerUrl,
  headscaleEnableSSH ? true,
}:
{
  lib,
  options,
  ...
}:
let
  hasHeadscaleOption = options ? networking && options.networking ? headscale;
  homeManagerExplicitlyDisabled =
    hostProfile ? enableHomeManager
    && hostProfile.enableHomeManager != null
    && hostProfile.enableHomeManager == false;
in
{
  imports = [ ../profile.nix ];

  config = {
    assertions = [
      {
        assertion = !homeManagerExplicitlyDisabled;
        message = ''
          hostProfile.enableHomeManager must not be set to false in host-common based hosts.
          Keep Home Manager enabled by default and rely on platform/bootstrap gating
          (modules/.common.d/default.nix) for NixOS bootstrap-specific behavior.
        '';
      }
    ];

    profile = {
      host = {
        hostName = lib.mkDefault hostProfile.hostName;
      }
      // (lib.optionalAttrs (hostProfile ? hostAlias) {
        hostAlias = lib.mkDefault hostProfile.hostAlias;
      })
      // (lib.optionalAttrs (hostProfile ? form) {
        form = hostProfile.form;
      });

      darwin = darwinProfile;
    };
  }
  // (lib.optionalAttrs hasHeadscaleOption {
    networking.headscale = {
      enable = true;
      serverUrl = headscaleServerUrl;
      enableSSH = headscaleEnableSSH;
    };
  });
}
