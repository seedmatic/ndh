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
  isTlsAuthority = name: builtins.elem "tls-authority" (authorities.${name}.usage or [ ]);

  # One anchor per slot carrying a minted `ca_crt`, named `<authority>@<slot>`, from
  # a per-authority slot set: the TRUSTED slots to install, the COMPROMISED ones to
  # remove (ndh.keysYaml, keys-yaml.d/trust.nix). Installing both trusted
  # generations is what lets a renewal overlap (keys.schema.yaml, authoritySlots).
  anchorsOf =
    slotSets:
    lib.listToAttrs (
      lib.concatLists (
        lib.mapAttrsToList (
          name: slots:
          lib.mapAttrsToList (slot: material: lib.nameValuePair "${name}@${slot}" material.ca_crt) (
            lib.filterAttrs (_: material: material ? ca_crt) slots
          )
        ) (lib.filterAttrs (name: _: isTlsAuthority name) slotSets)
      )
    );
  tlsAnchors = anchorsOf config.ndh.keysYaml.trustedAuthoritySlots;
  compromisedAnchors = anchorsOf config.ndh.keysYaml.compromisedAuthoritySlots;

  # Materialise each ca_crt PEM into the Nix store so the activation
  # snippet can reference a stable path.  `security add-trusted-cert`
  # accepts PEM directly.
  # A store name cannot carry `@`, so the file is `<authority>-<slot>-ca.crt`.
  writeAnchors = lib.mapAttrs (
    name: pem: pkgs.writeText "${lib.replaceStrings [ "@" ] [ "-" ] name}-ca.crt" pem
  );

  # Newline-separated "name:path" pairs for the script
  pairsOf =
    files: lib.concatStringsSep "\n" (lib.mapAttrsToList (name: file: "${name}:${file}") files);
  certPairs = pairsOf (writeAnchors tlsAnchors);
  compromisedPairs = pairsOf (writeAnchors compromisedAnchors);

  certCount = toString (builtins.length (lib.attrNames tlsAnchors));

  ndhContext = ndh.context;
  nixBashTrampoline = "${ndhContext.nixBashTrampoline}";

  tlsAuthorityKeychainScript = ndh.store.runCommand "tls-authority-keychain-post-activation.sh" { } ''
    cp ${
      pkgs.replaceVars ./tls-authority-keychain.d/post-activation.sh {
        inherit
          nixBashTrampoline
          certPairs
          compromisedPairs
          certCount
          ;
      }
    } "$out"
    chmod +x "$out"
  '';
in
{
  # `system.activationScripts.postActivation` runs as root after the
  # main system swap, so it has the rights `security add-trusted-cert
  # -k /Library/Keychains/System.keychain` needs.
  system.activationScripts.postActivation.text =
    lib.mkIf (tlsAnchors != { } || compromisedAnchors != { })
      (
        lib.mkAfter ''
          ${tlsAuthorityKeychainScript}
        ''
      );
}
