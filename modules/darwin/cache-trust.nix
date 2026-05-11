{
  config,
  lib,
  ...
}:
# Darwin wiring for the fleet cache signing compose step.
#
# nix-darwin's sops-install-secrets runs inline in
# system.activationScripts.postActivation.text at lib.mkOrder 1000;
# we append at mkOrder 1200 so our compose script lands after the bare
# private is in place at /run/secrets/<name>.key.bare.
#
# The compose script itself and the fleet trust settings come from
# modules/.common.d/cache-trust.nix.
{
  config.system.activationScripts.postActivation.text = lib.mkOrder 1200 ''
    ${config.ndh.cacheTrust.composeScript}/bin/cache-trust-compose
  '';
}
