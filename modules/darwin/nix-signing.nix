{
  config,
  lib,
  ...
}:
# Darwin wiring for the builder's derived nix signing key (modules/.common.d/nix-signing.nix). The host key it
# derives from is placed before activation, so the key is placed in its own slot (activation-order.nix). Adding the
# file to secret-key-files changes nix.conf, which nix-darwin does not restart the daemon for: ndh-switch does.
lib.mkIf config.ndh.nixSigning.signs {
  system.activationScripts.postActivation.text = lib.mkOrder config.ndh.darwin.postActivationOrder.nixSigningKey ''
    ${config.ndh.nixSigning.placeScript}/bin/ndh-nix-signing-key
  '';
}
