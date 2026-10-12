# Darwin-only: the System keychain holds EXACTLY each tls-authority's trusted roots, so
# Apple's SecTrust accepts what they sign and nothing a stale root signed.
#
# One script, `ndh-keychain-reconcile`, run by the activation, kept on PATH for the operator
# (`sudo ndh-keychain-reconcile` from the GUI session when an ssh switch could not apply a
# trust setting; `--check` reports only), and exported as a flake package so a fix ships
# between configurations. See ./tls-authority-keychain.d/post-activation.sh.
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

  reconcile = ndh.store.runCommand "ndh-keychain-reconcile" { } ''
    install -D -m 0755 ${
      pkgs.replaceVars ./tls-authority-keychain.d/post-activation.sh {
        inherit nixBashTrampoline certPairs;
        authorities = lib.concatStringsSep " " tlsAuthorities;
        openssl = "${pkgs.openssl}/bin/openssl";
      }
    } "$out/bin/ndh-keychain-reconcile"
  '';
in
{
  options.ndh.tlsAuthorityKeychain.package = lib.mkOption {
    type = lib.types.package;
    readOnly = true;
    default = reconcile;
    description = "`ndh-keychain-reconcile`: the System keychain holds exactly each tls-authority's trusted roots.";
  };

  config = lib.mkIf (tlsAuthorities != [ ]) {
    environment.systemPackages = [ reconcile ];

    # `system.activationScripts.postActivation` runs as root after the main system swap. It
    # runs whenever a tls-authority exists — even with no trusted slot, its stale roots go.
    # A trust setting it cannot apply over ssh fails the activation, naming the gesture.
    system.activationScripts.postActivation.text = lib.mkAfter ''
      ${reconcile}/bin/ndh-keychain-reconcile
    '';
  };
}
