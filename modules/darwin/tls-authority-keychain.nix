# Darwin-only: install every keys.yaml authority that advertises
# `tls-authority` usage into the System keychain so Apple's SecTrust
# accepts certs they sign.
#
# See ./tls-authority-keychain.d/post-activation.sh for implementation details.
{
  config,
  lib,
  pkgs,
  ndh,
  ...
}:
let
  authorities = config.ndh.keysYaml.authorities or { };
  isTlsAnchor = auth: (auth ? ca_crt) && (builtins.elem "tls-authority" (auth.usage or [ ]));
  tlsAnchors = lib.filterAttrs (_: isTlsAnchor) authorities;

  # Materialise each ca_crt PEM into the Nix store so the activation
  # snippet can reference a stable path.  `security add-trusted-cert`
  # accepts PEM directly.
  certFiles = lib.mapAttrs (name: auth: pkgs.writeText "${name}-ca.crt" auth.ca_crt) tlsAnchors;

  # Build a newline-separated list of "name:path" pairs for the script
  certPairs = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (name: certFile: "${name}:${certFile}") certFiles
  );

  certCount = toString (builtins.length (lib.attrNames tlsAnchors));

  ndhContext = ndh.context;
  nixBashTrampoline = "${ndhContext.nixBashTrampoline}";

  tlsAuthorityKeychainScript = ndh.store.runCommand "tls-authority-keychain-post-activation.sh" { } ''
    cp ${
      pkgs.replaceVars ./tls-authority-keychain.d/post-activation.sh {
        inherit nixBashTrampoline certPairs certCount;
      }
    } "$out"
    chmod +x "$out"
  '';
in
{
  # `system.activationScripts.postActivation` runs as root after the
  # main system swap, so it has the rights `security add-trusted-cert
  # -k /Library/Keychains/System.keychain` needs.
  system.activationScripts.postActivation.text = lib.mkIf (tlsAnchors != { }) (
    lib.mkAfter ''
      ${tlsAuthorityKeychainScript}
    ''
  );
}
