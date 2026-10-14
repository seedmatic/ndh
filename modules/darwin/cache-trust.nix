{
  config,
  lib,
  ...
}:
# Darwin wiring for the fleet cache signing compose step.
#
# The compose reads the bare private sops-nix installs at /run/secrets/<name>.key.bare, so it runs
# in the slot after the install (modules/darwin/activation-order.nix).
#
# The compose script itself and the fleet trust settings come from
# modules/.common.d/cache-trust.nix.
{
  config.system.activationScripts.postActivation.text =
    lib.mkOrder config.ndh.darwin.postActivationOrder.cacheTrustCompose ''
      ${config.ndh.cacheTrust.composeScript}/bin/cache-trust-compose
    '';
}
