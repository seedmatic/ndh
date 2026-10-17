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
    # Loud, but the rest of the activation goes on (nix-darwin's activate runs under set -e): a machine whose
    # placement fails keeps the previous key, or fails the builds that sign, and can still switch its fix.
    if ! ${config.ndh.nixSigning.placeScript}/bin/ndh-nix-signing-key; then
      echo "[nix-signing] FAILED at activation: this machine signs with no derived key until it is placed" >&2
    fi
  '';
}
