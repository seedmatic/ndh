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
  tlsAuthorities = lib.filter (
    name: builtins.elem "tls-authority" (authorities.${name}.usage or [ ])
  ) (lib.attrNames authorities);

  # One anchor per TRUSTED slot carrying a minted `ca_crt`, named `<authority>@<slot>`
  # (ndh.keysYaml.trustedAuthoritySlots, keys-yaml.d/trust.nix). Installing both trusted
  # generations is what lets a renewal overlap (keys.schema.yaml, authoritySlots); every
  # other root of the authority is removed by the script.
  tlsAnchors = lib.listToAttrs (
    lib.concatMap (
      name:
      lib.mapAttrsToList (slot: material: lib.nameValuePair "${name}@${slot}" material.ca_crt) (
        lib.filterAttrs (_: material: material ? ca_crt) (
          config.ndh.keysYaml.trustedAuthoritySlots.${name} or { }
        )
      )
    ) tlsAuthorities
  );

  # Materialise each ca_crt PEM into the Nix store so the activation
  # snippet can reference a stable path.  `security add-trusted-cert`
  # accepts PEM directly.
  # A store name cannot carry `@`, so the file is `<authority>-<slot>-ca.crt`.
  certFiles = lib.mapAttrs (
    name: pem: pkgs.writeText "${lib.replaceStrings [ "@" ] [ "-" ] name}-ca.crt" pem
  ) tlsAnchors;

  # Newline-separated "name:path" pairs for the script
  certPairs = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (name: file: "${name}:${file}") certFiles
  );

  ndhContext = ndh.context;
  nixBashTrampoline = "${ndhContext.nixBashTrampoline}";

  tlsAuthorityKeychainScript = ndh.store.runCommand "tls-authority-keychain-post-activation.sh" { } ''
    cp ${
      pkgs.replaceVars ./tls-authority-keychain.d/post-activation.sh {
        inherit nixBashTrampoline certPairs;
        authorities = lib.concatStringsSep " " tlsAuthorities;
        openssl = "${pkgs.openssl}/bin/openssl";
      }
    } "$out"
    chmod +x "$out"
  '';
in
{
  # `system.activationScripts.postActivation` runs as root after the
  # main system swap, so it has the rights `security add-trusted-cert
  # -k /Library/Keychains/System.keychain` needs. It runs whenever a
  # tls-authority exists — even with no trusted slot, its stale roots go.
  system.activationScripts.postActivation.text = lib.mkIf (tlsAuthorities != [ ]) (
    lib.mkAfter ''
      ${tlsAuthorityKeychainScript}
    ''
  );
}
