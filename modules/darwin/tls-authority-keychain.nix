# Darwin-only: install every keys.yaml authority that advertises
# `tls-authority` usage into the System keychain so Apple's SecTrust
# accepts certs they sign.
#
# Background: nix-darwin's `security.pki.certificates` writes the
# bundle at /etc/ssl/certs/ca-certificates.crt — which Go's pure-Go
# verifier honours via SSL_CERT_FILE, but Apple's SecTrust does NOT
# consult.  Anything that goes through Apple's frameworks (Tailscale's
# native daemon, every HTTPS call from a notarised Mac app, Safari,
# Chrome) needs the root in /Library/Keychains/System.keychain or an
# admin domain-trust policy.  `security add-trusted-cert -d -r trustRoot`
# achieves that with explicit "always trust" semantics scoped to the
# whole machine; idempotent — re-running on an already-trusted cert
# is a no-op.
#
# Apple's SecTrust accepts ECDSA P-256 roots cleanly.  An earlier
# attempt to install the Ed25519 `mammoth-skate` root failed with
# "Unknown format in import" — Apple's Security framework rejects the
# curve at trust-insertion time.  This module silently skips any root
# the keychain refuses (e.g. an Ed25519 holdout); the bundle path
# continues to carry it for Go-verifier consumers.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  authorities = config.ndh.keysYaml.authorities or { };
  isTlsAnchor =
    auth:
    (auth ? ca_crt) && (builtins.elem "tls-authority" (auth.usage or [ ]));
  tlsAnchors = lib.filterAttrs (_: isTlsAnchor) authorities;

  # Materialise each ca_crt PEM into the Nix store so the activation
  # snippet can reference a stable path.  `security add-trusted-cert`
  # accepts PEM directly.
  certFiles = lib.mapAttrs (
    name: auth: pkgs.writeText "${name}-ca.crt" auth.ca_crt
  ) tlsAnchors;

  installCommands = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (name: certFile: ''
      # ${name}: idempotent — `add-trusted-cert` is a no-op when the
      # cert is already in the keychain at the same trust scope.
      if ! /usr/bin/security add-trusted-cert -d -r trustRoot \
            -k /Library/Keychains/System.keychain ${certFile} 2>/dev/null; then
        echo "[tls-authority-keychain] WARN: SecTrust refused ${name} (likely Ed25519); leaving SSL_CERT_FILE-only" >&2
      fi
    '') certFiles
  );
in
{
  # `system.activationScripts.postActivation` runs as root after the
  # main system swap, so it has the rights `security add-trusted-cert
  # -k /Library/Keychains/System.keychain` needs.
  system.activationScripts.postActivation.text =
    lib.mkIf (tlsAnchors != { })
      (lib.mkAfter ''
        echo "[tls-authority-keychain] reconciling ${toString (builtins.length (lib.attrNames tlsAnchors))} tls-authority root(s) with /Library/Keychains/System.keychain"
        ${installCommands}
      '');
}
