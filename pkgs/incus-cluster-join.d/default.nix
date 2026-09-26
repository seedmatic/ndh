# `<host>-incus-cluster-join` — join one itinerant Incus member to the cluster whose bootstrap member
# is the sedentary bare-metal.  An OPERATOR app, deliberately, and not a unit on the joining host:
# see the rationale in join.sh and in modules/nixos/incus-cluster.nix.
#
# Self-contained on purpose (the `manage-tailnet.d` shape rather than the `baremetal-link.d` one):
# this directory owns its recipe, and flake.nix only supplies the facts it alone can see.  The
# alternative — a `mkIncusClusterJoin` helper in flake.nix reading ./join.sh — puts the recipe 800
# lines from the script it drives, in a directory that advertises derivations; manage-tailnet.d's own
# header already names that as the reason it lives this way.
#
# Inputs
#   - `catalog.netplan.baremetal` — the fleet's bare-metals: who is sedentary (`lanAttachment`), and
#                                   each one's `domain`, from which the member name and the `nixos.`
#                                   FQDN both derive.  The set of hosts is CLOSED and derivable, so
#                                   the apps are enumerated rather than parameterised.
#   - `storagePools`               — `<domain> -> { name, source }`, read by flake.nix from that
#                                   host's OWN `virtualisation.incus.preseed.storage_pools`. Passed
#                                   in rather than restated because the source is member-specific —
#                                   it is the one thing `incus admin init --preseed` needs in
#                                   `member_config` — and the preseed is its single source of truth.
#   - `ndhStore.installBinScript`  — the bash-trampoline bin wrapper
#   - `nixBashTrampoline`          — the shared nix-managed bash + logger + env
#
# Returns an attrset keyed by the JOINING host's domain, e.g. `{ nikopol = <package>; }`.
{
  pkgs,
  catalog,
  ndhStore,
  nixBashTrampoline,
  storagePools,
}:
let
  baremetals = builtins.attrValues (catalog.netplan.baremetal or { });

  # The bootstrap member is the SEDENTARY one, derived rather than chosen: a roaming host cannot be
  # the member others join, since its address and its presence both move.  Same derivation as
  # modules/nixos/incus-cluster.nix, from the same catalog field.
  sedentary = builtins.filter (e: (e.lanAttachment or "roaming") == "fixed") baremetals;
  bootstrapEntry = if sedentary == [ ] then null else builtins.head sedentary;

  # Everyone else joins.  A single-baremetal fleet therefore produces NO app, which is correct: there
  # is nothing to join.
  joiners = builtins.filter (
    e: bootstrapEntry != null && e.domain != bootstrapEntry.domain
  ) baremetals;

  # `<host>-nixos` — the same convention the host's tailnet node, its Incus remote label and its
  # NixOS configuration already carry, so one name identifies the daemon everywhere.
  memberNameOf = entry: "${entry.domain}-nixos";

  # The one name form for an infra host (rke2lab's `NamePlan.nixosFabricFqdn`, ndh's catalog record):
  # served by that host's own dnsmasq in its `.<host>` zone and reachable over the tailnet split-DNS.
  # Not `<host>-nixos.local` (mDNS dies across a routed boundary) and not the tailnet name (which is
  # what a renew changes).
  sshTargetOf = entry: "nixos.${entry.domain}";

  mkJoin =
    entry:
    let
      pool =
        storagePools.${entry.domain}
          or (throw "incus-cluster-join: no storage pool given for ${entry.domain}");
    in
    ndhStore.installBinScript "${entry.domain}-incus-cluster-join" (
      pkgs.replaceVars ./join.sh {
        inherit nixBashTrampoline;
        loggerTag = "ndh.incus-cluster-join";
        # Pinned by store path because the trampoline owns PATH.
        ssh = "${pkgs.openssh}/bin/ssh";
        # ssh's ConnectTimeout does not cover NAME RESOLUTION, so a hard timeout wraps it — the
        # lesson the baremetal-link deploy learned when a segment's resolver moved.
        timeout = "${pkgs.coreutils}/bin/timeout";
        # Structural parsers, because both facts this script branches on were measured to be
        # unmatchable by the obvious grep (see join.sh).  jq for the daemon's JSON, yq-go for
        # `incus cluster show`'s YAML — the same pair modules/nixos/incus-cluster.nix uses.
        jq = "${pkgs.jq}/bin/jq";
        yq = "${pkgs.yq-go}/bin/yq";
        joiningMember = memberNameOf entry;
        bootstrapMember = memberNameOf bootstrapEntry;
        joiningSsh = sshTargetOf entry;
        bootstrapSsh = sshTargetOf bootstrapEntry;
        poolName = pool.name;
        poolSource = pool.source;
      }
    );
in
builtins.listToAttrs (
  map (entry: {
    name = entry.domain;
    value = mkJoin entry;
  }) joiners
)
