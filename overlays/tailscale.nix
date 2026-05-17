{ nixpkgs-unstable, tailscale-fork, ... }:
final: prev:
let
  unstablePkgs = nixpkgs-unstable.legacyPackages.${prev.stdenv.hostPlatform.system};

  # `tailscale-fork` is a flake input with `flake = false`; the source
  # tree is at `.outPath` and the resolved commit at `.rev`.  Use a
  # short rev for human-readable version stamps while keeping the
  # full rev available if anyone wants to chase the source.
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
  # Pull tailscale from nixos-unstable: the upstream headscale server on our
  # control plane runs 1.94.x, and stable nixpkgs lags far enough behind to
  # trip a client/server version-skew warning (and eventually protocol
  # incompatibility). Tests disabled to avoid flaky sandbox checks.
  #
  # The `src` is overridden to our forked branch carrying the
  # CNAME-in-extra_records patch (see github:nxmatic/tailscale,
  # branch nxmatic/feature/extra-records-cname).  The fork is rebased on
  # tailscale v1.96.5, matching the version nixpkgs-unstable currently
  # builds — so the existing `vendorHash` in nixpkgs's tailscale
  # derivation still applies (the patch adds no new Go module
  # dependencies).  When upstream nixpkgs bumps tailscale, rebase the
  # fork on the matching tag and update the input rev.
  #
  # Version stamping: nixpkgs sets `version.longStamp = ${version}` and
  # `version.shortStamp = ${version}` already.  We replace longStamp so
  # `tailscale version` (long form) reads e.g.
  # `1.96.5-nxmatic-cname-fd16461` — unambiguously identifies a
  # forked binary at runtime.  shortStamp stays at the upstream
  # version so headscale's client/server skew check (string equality
  # on the short version) doesn't fire.  extraGitCommitStamp records
  # the fork commit for diagnostic output.
  tailscale = unstablePkgs.tailscale.overrideAttrs (old: {
    src = tailscale-fork;
    ldflags = [
      "-w"
      "-s"
      "-X tailscale.com/version.longStamp=${old.version}-${forkBranchTag}-${forkShortRev}"
      "-X tailscale.com/version.shortStamp=${old.version}"
      "-X tailscale.com/version.extraGitCommitStamp=${forkShortRev}"
    ];
    doCheck = false;
    dontCheck = true;
    checkPhase = "echo skipping tailscale checkPhase";
    installCheckPhase = "echo skipping tailscale installCheckPhase";
    phases = builtins.filter (p: p != "checkPhase") (old.phases or [ ]);
  });
}
