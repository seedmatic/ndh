{
  description = "nix system configurations";

  # Inputs are organized into three groups to keep the surface scannable:
  #
  #   1. Aggregator pin — `flake-commons` is the single source of truth for
  #      most third-party flakes. Bump that flake to roll a coordinated set
  #      of dependencies across all consumers.
  #   2. Aggregator passthroughs — every entry is `follows = "flake-commons/<x>";`.
  #      Listed alphabetically so adds/removes diff cleanly.
  #   3. Direct inputs — flakes pinned here because flake-commons does not
  #      re-export them (`treefmt-nix`, `sops-nix`) or because they're
  #      project-local (`tailscale-fork`).
  #
  # Every SEEDMATIC-owned input below is an INDIRECT id (`url = "flake-commons"`),
  # resolved through nix's registry: the branch-less default targets live in the
  # committed flake-registry.json, and the operator re-aims one by dropping a
  # flake-registry.local.json beside it (see the [hook] in .flox/env/manifest.toml).
  #
  # Why, and it is not a preference: this chain is PUSH-GATED, so a branch named here
  # could only be re-aimed by pushing an edit to this file — which is precisely how the
  # same pin rotted twice, advancing along a line nobody was on without ever erroring.
  # Naming no branch means naming nothing that can be deleted.
  #
  # Hermeticity is unaffected, measured: an indirect id is consulted only when
  # RE-locking. flake.lock still records a revision, so anyone evaluating this flake
  # from the lock — with no registry at all — resolves exactly what we resolved.
  inputs = {
    # 1. Aggregator pin
    flake-commons.url = "flake-commons";

    # 2. Aggregator passthroughs (alphabetized)
    chromium-bin.follows = "flake-commons/chromium-bin";
    darwin.follows = "flake-commons/darwin";
    disko.follows = "flake-commons/disko";
    flake-compat.follows = "flake-commons/flake-compat";
    flake-utils.follows = "flake-commons/flake-utils";
    flox.follows = "flake-commons/flox";
    home-manager.follows = "flake-commons/home-manager";
    impermanence.follows = "flake-commons/impermanence";
    maven-mvnd.follows = "flake-commons/maven-mvnd";
    nixos-hardware.follows = "flake-commons/nixos-hardware";
    nixpkgs.follows = "flake-commons/nixpkgs";
    nixpkgs-unstable.follows = "flake-commons/nixpkgs-unstable";
    llm-agents.follows = "flake-commons/llm-agents";
    sops-nix.follows = "flake-commons/sops-nix";
    treefmt-nix.follows = "flake-commons/treefmt-nix";

    # The fabric's two deliveries, pinned as DATA rather than as the flakes that produce them.
    # rke2lab's plan is the source of truth for the cluster network underlay (cluster/node IDs,
    # MACs, addressing) and for the cluster dataset layout: netplan.json and dataplan.json on its
    # fabric/plan orphan, which rke2lab's publish-plan writes. nnh's contribution is its fabric-br
    # segments: network-blueprint.json on its fabric/contribution orphan. ndh used to pin rke2lab
    # and nnh themselves, each of which pins ndh back — two cycles, cut at the lock by reciprocal
    # empty follows. An orphan pins nothing, so no cycle is left to cut.
    fabric-plan.url = "fabric-plan";
    fabric-plan.flake = false;
    nnh-contribution.url = "nnh-contribution";
    nnh-contribution.flake = false;

    # Forked tailscale carrying our patches (see overlays/tailscale.nix):
    # the CNAME-in-extra_records resolver support and the SSH-interception
    # port-2222 switch, rebased onto upstream's release-branch/1.102 as the
    # single `nxmatic/integration/1.102` branch. The fork is consumed as a
    # real flake — it builds itself via upstream tailscale's own
    # `flakehashes.json` (vendorHash + go-toolchain SRI, kept in sync with
    # go.mod by upstream), so vendorHash is decoupled from whatever
    # tailscale version nixpkgs-unstable happens to ship. `nixpkgs` is
    # pinned to flake-commons so the fork's binaries share a
    # glibc/openssl/etc with the rest of the closure.
    tailscale-fork = {
      url = "github:nxmatic/tailscale/nxmatic/integration/1.104";
      inputs.nixpkgs.follows = "flake-commons/nixpkgs";
    };
  };

  outputs = inputs: (import ./flake/outputs.nix) inputs;
}
