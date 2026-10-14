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
  # nix-daemon reads secret-key-files once, at start, and a switch that only rewrites nix.conf does
  # not restart it on darwin: measured signing with the retired key after the rotation.
  config.ndh.restartOnSecretChange."org.nixos.nix-daemon" = {
    domain = "system";
    secrets = map (name: "${name}.key.bare") config.ndh.cacheTrust.cachixNames;
    reason = "the fleet signing key changed (builds in flight are interrupted)";
  };

  config.system.activationScripts.postActivation.text =
    lib.mkOrder config.ndh.darwin.postActivationOrder.cacheTrustCompose ''
      ${config.ndh.cacheTrust.composeScript}/bin/cache-trust-compose
    '';
}
