# Common VM materializer options — shared gate for Lima and Tart activation hooks.
#
# Provides a single top-level switch to disable all VM materialization during
# darwin-rebuild activation, regardless of the selected vmProvider.
#
# Reads from hostProfile.vmMaterializerEnableActivationHook if set, otherwise defaults to true.
{
  lib,
  config,
  ndh,
  ...
}:
with lib;
let
  ndhContext = ndh.context;
  hostProfile = ndhContext.hostProfile or { };
in
{
  options.vmMaterializer = {
    enableActivationHook = mkOption {
      type = types.bool;
      default = hostProfile.vmMaterializerEnableActivationHook or true;
      description = ''
        Master switch for VM materialization during darwin activation.
        When false, disables both Lima and Tart activation hooks.
        Individual provider hooks (lima.configGenerator.enableActivationHook,
        tart.configGenerator.enableActivationHook) can further refine behavior.

        Can be set via hostProfile.vmMaterializerEnableActivationHook in host configuration.
      '';
    };
  };
}
