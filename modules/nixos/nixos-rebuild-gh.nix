# `nixos-rebuild-gh`: nixos-rebuild with a GitHub access token sourced from
# `gh auth token`, so `github:` flake fetches authenticate and dodge the
# anonymous-tarball 429 rate limit — WITHOUT a plaintext token in
# ~/.config/nix/nix.conf.  Matches ndh's "no static token" stance (see
# modules/darwin/github-mcp-proxy.nix): the token is fetched at run time from
# the invoking user's gh session and passed to the sudo'd rebuild via --option,
# never written to disk.
#
# Usage (on the host):  nixos-rebuild-gh switch --refresh --flake <ref>#<host>
# Requires the invoking user to be logged in: `gh auth status` / `gh auth login`.
{ pkgs, ... }:
let
  nixosRebuildGh = pkgs.writeShellScriptBin "nixos-rebuild-gh" ''
    set -euo pipefail
    token="$(${pkgs.gh}/bin/gh auth token 2>/dev/null || true)"
    if [ -z "$token" ]; then
      echo "nixos-rebuild-gh: no token from 'gh auth token' — run 'gh auth login' (or set GH_TOKEN)" >&2
      exit 1
    fi
    # gh auth token ran as the invoking user; only the rebuild is elevated.
    exec sudo nixos-rebuild "$@" --option access-tokens "github.com=$token"
  '';
in
{
  environment.systemPackages = [
    nixosRebuildGh
    pkgs.gh
  ];
}
