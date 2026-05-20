{ tailscale-fork, ... }:
final: prev:
let
  # Use the fork's own `flake.nix` to build tailscale: it carries
  # `flakehashes.json` (vendorHash + go toolchain SRI) keyed to whatever
  # upstream tag the fork is currently rebased on, so the build is
  # decoupled from nixpkgs-unstable's package version. To roll the fork:
  #
  #   1. In /private/var/lib/git/tailscale/tailscale, rebase the
  #      `nxmatic/feature/extra-records-cname` branch onto the new
  #      upstream tag.
  #   2. Run `nix run .#tool-updateflakes` (or whatever the fork's flake
  #      exposes) to refresh `flakehashes.json` if go.mod changed.
  #   3. `git push --force-with-lease`.
  #   4. From this repo: `nix flake update tailscale-fork`.
  forkPkgs = tailscale-fork.packages.${prev.stdenv.hostPlatform.system};

  # The fork's flake builds with `name = "tailscale"; pname = "tailscale";`
  # but no `version` attribute, so the upstream version (which headscale's
  # client/server skew check matches against) has to be read out of
  # `VERSION.txt` in the source tree.
  forkVersion =
    let
      raw = builtins.readFile "${tailscale-fork}/VERSION.txt";
    in
    builtins.replaceStrings [ "\n" ] [ "" ] raw;

  forkShortRev =
    if tailscale-fork ? shortRev then
      tailscale-fork.shortRev
    else if tailscale-fork ? rev then
      builtins.substring 0 7 tailscale-fork.rev
    else
      "unknown";
  forkBranchTag = "nxmatic-cname";
in
{
  # The fork's `packages.<system>.tailscale` is built from the patched
  # source tree directly. We layer version stamping on top so
  # `tailscale version --long` advertises the fork commit and branch
  # tag while leaving `shortStamp` at the upstream version (headscale's
  # client/server skew check is a string-equality on the short stamp,
  # so it must match what an unpatched client of the same upstream tag
  # would report).
  tailscale = forkPkgs.tailscale.overrideAttrs (old: {
    version = forkVersion;
    ldflags = (old.ldflags or [ ]) ++ [
      "-X tailscale.com/version.longStamp=${forkVersion}-${forkBranchTag}-${forkShortRev}"
      "-X tailscale.com/version.shortStamp=${forkVersion}"
      "-X tailscale.com/version.extraGitCommitStamp=${forkShortRev}"
    ];
  });
}
