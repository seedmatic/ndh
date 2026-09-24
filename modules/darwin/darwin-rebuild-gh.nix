# `darwin-rebuild-gh`: the darwin twin of modules/nixos/nixos-rebuild-gh.nix —
# darwin-rebuild with a GitHub access token sourced from `gh auth token`, so
# `github:` flake fetches authenticate.  Same stance, same mechanism, same
# reason it cannot be a nix.conf setting: ndh writes no static token to disk
# (see modules/darwin/github-mcp-proxy.nix).
#
# WHY A DARWIN TWIN AT ALL.  The NixOS wrapper only equips the case "I am logged
# in ON the guest", because it lands in that guest's systemPackages.  Every
# rebuild in practice is DRIVEN FROM A MAC — the guests are rebuilt with
# `--target-host`, and the Macs rebuild themselves — so the path that is actually
# used had no equipment at all.  Measured 2026-09-24 on nikopol, whose store was
# cold for a private input:
#
#   error: unable to download '…/claude-hub/archive/<sha>.tar.gz': HTTP error 404
#
# That 404 is what makes it worth a module rather than a remembered flag. GitHub
# answers 404 — not 403 — for a private repo fetched anonymously, so the message
# reads as "this revision does not exist" while `git ls-remote` finds it happily.
# The cost is not the missing token, it is the half hour spent doubting the
# revision.  It had never surfaced before only because the other Mac's store
# already carried the input, so no fetch occurred.
#
# Usage:  darwin-rebuild-gh switch --flake <ref>#<host>
# Requires the invoking user to be logged in: `gh auth status` / `gh auth login`.
{ pkgs, ... }:
let
  darwinRebuildGh = pkgs.writeShellScriptBin "darwin-rebuild-gh" ''
    set -euo pipefail
    token="$(${pkgs.gh}/bin/gh auth token 2>/dev/null || true)"
    if [ -z "$token" ]; then
      echo "darwin-rebuild-gh: no token from 'gh auth token' — run 'gh auth login' (or set GH_TOKEN)" >&2
      exit 1
    fi
    # `gh auth token` ran as the invoking user; darwin-rebuild elevates itself for
    # switch, so this wrapper does NOT sudo — unlike the NixOS twin, where the
    # rebuild must be elevated explicitly.
    exec darwin-rebuild "$@" --option access-tokens "github.com=$token"
  '';
in
{
  environment.systemPackages = [
    darwinRebuildGh
    pkgs.gh
  ];
}
