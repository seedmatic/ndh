{ lib, pkgs, ... }:
# Remove any UseKeychain directive from ~/.ssh/config (@codebase)
# Always run using GNU sed from Nix store; no pre-checks required. Idempotent.
# Pattern: a line consisting solely of optional leading whitespace, 'UseKeychain'
# one or more spaces, 'yes', optional trailing whitespace or inline comment.
{
  home.activation.removeUseKeychain = lib.hm.dag.entryAfter [ "writeBoundary" ] (
    builtins.readFile (
      pkgs.replaceVars ./ssh-keychain-removal.d/remove-use-keychain.sh {
        sed = "${pkgs.gnused}/bin/sed";
      }
    )
  );
}
