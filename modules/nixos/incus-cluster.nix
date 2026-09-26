{
  config,
  pkgs,
  lib,
  ndh,
  ...
}:
# Incus clustering for the bare-metal fleet: the two `<host>-nixos` daemons joined into ONE cluster,
# so a client talks to the member it can reach and operates instances on either — "you can operate
# each instance from any cluster member, so you do not need to log on to the cluster member on which
# the instance is located".  That is what removes the cross-host reach problem for the infrastructure
# API: a pod on the sedentary host dials its LOCAL member and provisions on the itinerant one, with
# no egress and no tailnet on that path.  Placement is CAPN's `LXCMachineTemplate.spec.target`, whose
# own description calls a clustered Incus "a production cluster" and the single-node case
# "development purposes".
#
# ★ THE LOAD-BEARING SETTING is `database-client` on the ITINERANT member.  `cluster.max_voters`
# must be an odd number >= 3, so it cannot be lowered to keep a two-member cluster single-voter;
# the only lever is that role, which "prevents the affected cluster member from being elected as a
# voter or stand-by".  Without it BOTH members vote, the majority is 2, and the itinerant host
# leaving takes the SEDENTARY host's database down with it — the host that carries every live
# cluster.  That is a regression traded for a convenience, so the role is not best-effort here: it
# is reconciled AND asserted (see incus-cluster-roles below).
#
# Availability with one voter is an INFERENCE, not a documented guarantee: the rule is "the database
# remains available as long as a majority of voters is online" (majority of 1 = 1), and a standalone
# Incus already runs a one-voter dqlite — but the docs recommend >= 3 members and never bless a
# single voter. The failure mode is bounded: it shows up the first time the itinerant member leaves,
# and the exit is `incus cluster remove <member> --force` back to standalone.
#
# Why this is not in the preseed. Clustering needs a CONCRETE member address, and ours is the tailnet
# address — assigned by the control plane, so not a build-time fact (`core.https_address` stays the
# `[::]:8443` wildcard for ordinary clients; `cluster.https_address` is Local scope and carries the
# member identity).  Both modes therefore run the same enrolment at boot, reading the address off
# `tailscale0` rather than restating it.  The join half additionally needs a token, which is
# single-use and expires in 3h — a credential that must be fetched at the moment of use, never
# persisted into an image.
let
  netplan = ndh.context.catalog.netplan or { };
  hostProfile = config.profile.host;
  effectiveHostName =
    if (hostProfile ? hostAlias && hostProfile.hostAlias != null && hostProfile.hostAlias != "") then
      hostProfile.hostAlias
    else
      hostProfile.hostName;

  bm = netplan.baremetal.${effectiveHostName} or null;
  enabled = bm != null;

  # The Incus member name for a bare-metal — the same `<host>-nixos` convention its tailnet node and
  # its incus remote label already carry, so one name identifies the daemon everywhere.
  memberNameOf = entry: "${entry.domain}-nixos";

  # The bootstrap member is the SEDENTARY one, and that is derived rather than chosen: a roaming host
  # cannot be the member others join (its address and its presence both move).  `lanAttachment` is
  # already the catalog's word for that asymmetry — the same field that decides who advertises the
  # home LAN route.
  baremetals = lib.attrValues (netplan.baremetal or { });
  sedentary = lib.filter (e: (e.lanAttachment or "roaming") == "fixed") baremetals;
  bootstrapEntry = if sedentary == [ ] then null else builtins.head sedentary;
  isBootstrap = enabled && bootstrapEntry != null && bootstrapEntry.domain == bm.domain;

  memberName = if enabled then memberNameOf bm else "";

  # One POSTURE — short-lived tokens — read from where it is already declared rather than restated.
  # `core.remote_token_expiry` governs trust-store tokens and `cluster.join_token_expiry` governs
  # cluster membership: different tokens, same intent, and a second literal is how two values come to
  # disagree.
  joinTokenExpiry = config.virtualisation.incus.preseed.config."core.remote_token_expiry" or "10M";

  # This member's own address for cluster traffic. Read off the interface, not from the tailscale
  # CLI: the fact is the same and it costs no dependency on which tailscale build runs here.
  tailnetAddressSnippet = ''
    member_address="$(${pkgs.iproute2}/bin/ip -4 -o addr show tailscale0 \
      | ${pkgs.gawk}/bin/awk '{print $4}' | ${pkgs.coreutils}/bin/cut -d/ -f1)"
    if [ -z "$member_address" ]; then
      echo "incus-cluster: tailscale0 carries no IPv4 yet — will retry" >&2
      exit 1
    fi
  '';

  # A function rather than an interpolated snippet: this is a MULTI-LINE command, and splicing it
  # into `if …; then` would put the `;` on a line of its own — a bash syntax error.
  isClusteredFn = ''
    is_clustered() {
      ${pkgs.incus}/bin/incus query /1.0 \
        | ${pkgs.jq}/bin/jq -e '.environment.server_clustered == true' >/dev/null 2>&1
    }
  '';

  # A RECONCILER, not a one-shot: the `admin init` half runs once (enrolling an already-clustered
  # daemon is an error, so that guard is ours to write), but the cluster-wide settings below are
  # re-asserted on every activation. Measured 2026-09-26, and the reason this is not a one-shot:
  # `cluster.images_minimal_replica` passed in the preseed's `config:` **silently did not apply**
  # while `cluster.https_address` in the same block did. The difference is scope — the address is
  # Local and part of forming the cluster, the replica count is Global and needs the cluster to
  # already exist. Chicken-and-egg inside one command, and it fails QUIETLY: the cluster came up
  # "Fully operational" with the key simply absent from `incus config show`.
  bootstrapScript = pkgs.writeShellApplication {
    name = "incus-cluster-bootstrap";
    text = ''
      ${isClusteredFn}
      if is_clustered; then
        echo "incus-cluster: already a member — reconciling cluster-wide settings only"
      else
        ${tailnetAddressSnippet}
        echo "incus-cluster: enabling clustering as ${memberName} on $member_address:8443"
        ${pkgs.incus}/bin/incus admin init --preseed <<EOF
      config:
        cluster.https_address: $member_address:8443
      cluster:
        server_name: ${memberName}
        enabled: true
      EOF
      fi

      # `-1` = "copy to ALL members". The DEFAULT replicates an image on "as many cluster members as
      # there are database members", and the itinerant member deliberately is not one — so under the
      # default it may hold no copy at all.
      #
      # ⚠️ WHY that matters is an INFERENCE, not a measured fact, and it is the weakest link in this
      # module. The claim behind `-1` was that a member without the image "has nothing to provision
      # from". That is unverified: if Incus copies an image to the target member on demand, then not
      # prefetching costs nothing functionally and `-1` ships gibibytes for no reason.
      #
      # So the real question is not correctness but WHEN the transfer happens:
      #   - `-1` (prefetch): always paid, but while the itinerant host is home on a good link.
      #   - default (on demand): paid only when provisioning there, possibly over a hotspot or a
      #     relay — i.e. at the worst moment.
      # Measurable now that the cluster has two members and no images: watch where the first image
      # lands, then whether `incus launch --target <itinerant>` fetches it by itself. Settle this by
      # observation rather than leaving an assumption that reads like a conclusion.
      # `--` before the positional args, and it is load-bearing: without it the cobra parser reads
      # `-1` as a shorthand FLAG and the command dies with "unknown shorthand flag: '1' in -1".
      echo "incus-cluster: asserting cluster.images_minimal_replica=-1"
      ${pkgs.incus}/bin/incus config set -- cluster.images_minimal_replica -1

      # Match the join token's lifetime to how it is actually USED. A join token is minted and
      # consumed within seconds by the operator app, so the 3h default is not a requirement but a
      # credential left lying around — and this is the ONE secret in the chain that cannot be
      # build-time material, so its window is the whole of its exposure. 10M is the posture
      # `core.remote_token_expiry` already sets for trust tokens; these are DIFFERENT tokens
      # (trust-store entry vs cluster membership), so that setting does not cover this one.
      echo "incus-cluster: asserting cluster.join_token_expiry=${joinTokenExpiry}"
      ${pkgs.incus}/bin/incus config set cluster.join_token_expiry ${joinTokenExpiry}
    '';
  };

  # Guard for the nixpkgs preseed unit, whose ExecStart is a BARE `incus admin init --preseed` with no
  # clustering check of its own (read 2026-09-26: one line, no guard).  It is `Type=oneshot` +
  # `RemainAfterExit`, so it does not re-run by itself — but any rebuild that CHANGES the preseed
  # restarts it, and on a clustered member it then tries to (re)create pools the cluster already owns.
  # That is not hypothetical: it is the exact refusal the first join attempt hit,
  # `Config key "source" is cluster member specific`.
  #
  # `ExecCondition` rather than a wrapper around ExecStart: a non-zero ExecCondition makes systemd SKIP
  # the unit and record it as succeeded, which is the honest outcome — there is nothing to preseed on a
  # member whose storage and networks are cluster-owned. A wrapper would have to fake success instead.
  # (Exit 1..254 = skip; 255 or a signal = genuine failure. So the guard exits 1, never 255.)
  #
  # Ordering is already right: the preseed runs after incus.service, so the daemon is up and can be
  # asked. And on the bootstrap member at FIRST boot the sequence is preseed (creates the pool) then
  # incus-cluster-bootstrap (forms the cluster) — so the guard passes exactly when the preseed is still
  # the thing that should run.
  preseedGuardScript = pkgs.writeShellApplication {
    name = "incus-preseed-guard";
    text = ''
      ${isClusteredFn}
      if is_clustered; then
        echo "incus-preseed-guard: this member is CLUSTERED — its storage and networks are cluster-owned, skipping the preseed"
        exit 1
      fi
      echo "incus-preseed-guard: standalone — the preseed is still this member's own business"
    '';
  };

  # Reconcile + ASSERT the roles of every OTHER member: each must be `database-client`, i.e. out of
  # the raft.  The assertion is the point — a role that silently failed to apply is exactly the
  # regression this whole design exists to avoid, and it would only surface as an outage the next
  # time the itinerant member left.
  rolesScript = pkgs.writeShellApplication {
    name = "incus-cluster-roles";
    text = ''
      if ! ${pkgs.incus}/bin/incus query /1.0 \
        | ${pkgs.jq}/bin/jq -e '.environment.server_clustered == true' >/dev/null 2>&1; then
        echo "incus-cluster-roles: not clustered yet — nothing to reconcile"
        exit 0
      fi

      members="$(${pkgs.incus}/bin/incus cluster list --format json \
        | ${pkgs.jq}/bin/jq -r '.[] | .server_name')"

      failed=0
      for member in $members; do
        [ "$member" = "${memberName}" ] && continue

        roles="$(${pkgs.incus}/bin/incus cluster show "$member" \
          | ${pkgs.yq-go}/bin/yq -r '.roles | join(",")')"

        case ",$roles," in
          *,database-client,*) ;;
          *)
            echo "incus-cluster-roles: pinning $member out of the raft (roles: $roles)"
            ${pkgs.incus}/bin/incus cluster role add "$member" database-client || true
            roles="$(${pkgs.incus}/bin/incus cluster show "$member" \
              | ${pkgs.yq-go}/bin/yq -r '.roles | join(",")')"
            ;;
        esac

        # ★ And keep automatic placement away from this member.  Incus, verbatim: "the automatic
        # assignment picks the cluster member that has the lowest number of instances. If several
        # members have the same amount of instances, one of the members is CHOSEN AT RANDOM."  With
        # two empty members that is a coin toss — so a `bioskop-mgmt` node could be born on nikopol,
        # look for a lease on nikopol's 10.80.16/21 while its deterministic reservation lives in
        # bioskop's dnsmasq, and take the whole addressing plan with it.
        #
        # `scheduler.instance = manual` excludes a member from automatic selection entirely: it then
        # receives only what is placed there DELIBERATELY (`--target`, or CAPN's
        # LXCMachineTemplate.spec.target).  That is exactly the posture we want for every member other
        # than the one whose segment a cluster is addressed on — and it is the safer default, because
        # it fails by refusing to place rather than by placing somewhere wrong.
        scheduler="$(${pkgs.incus}/bin/incus cluster show "$member" \
          | ${pkgs.yq-go}/bin/yq -r '.config."scheduler.instance" // ""')"
        if [ "$scheduler" != "manual" ]; then
          echo "incus-cluster-roles: excluding $member from automatic placement (was: ''${scheduler:-<unset>})"
          if ! ${pkgs.incus}/bin/incus cluster set "$member" scheduler.instance manual; then
            echo "incus-cluster-roles: FAULT — could not set scheduler.instance=manual on $member." \
                 "An untargeted instance may be placed there AT RANDOM." >&2
            failed=1
          fi
        fi

        # The assertion. `database` is the voter role; an itinerant voter means its absence costs
        # THIS host its quorum, so refuse to report success while that is true.
        case ",$roles," in
          *,database,*)
            echo "incus-cluster-roles: FAULT — $member is a VOTER (roles: $roles). Its absence will" \
                 "take this member's database with it; database-client did not apply." >&2
            failed=1
            ;;
        esac
      done

      exit "$failed"
    '';
  };
in
lib.mkIf enabled {
  # Applies to EVERY member, not just the bootstrap one: nikopol is the member whose preseed would
  # now fight the cluster, since the join discarded its local pool in favour of the cluster's.
  systemd.services.incus-preseed.serviceConfig.ExecCondition = lib.getExe preseedGuardScript;

  # Bootstrap runs on the sedentary member only, and the JOIN is deliberately NOT here.
  #
  # A join token is single-use and expires in 3h, with no documented alternative for a
  # non-interactive join. That rules out baking one into an image — it would start ageing before the
  # VM boots and make the image good for exactly one join, inside one window. So the token must be
  # minted and consumed in the same breath, which makes the join an OPERATOR act rather than host
  # state: `nix run` on the operator's machine, minting on this member over the access the operator
  # already has and handing it straight to the joining one.
  #
  # The alternative was a unit on the joining member fetching its own token over a capability
  # bounded to "mint MY token" (ndh keys already carry `authorized_keys_options`, so the mechanism
  # exists). Rejected because it answers a question that does not need asking: a join happens ONCE
  # per member, and that member is materialised by an operator command anyway, so autonomy buys
  # nothing and costs a distributed keypair plus a standing right to invite members. Who joins a
  # cluster is the operator's authority, not a member's.
  #
  # What stays declarative is what is genuinely idempotent host state: enabling clustering here, and
  # reconciling the roles below.
  systemd.services.incus-cluster-bootstrap = lib.mkIf isBootstrap {
    description = "Enable Incus clustering on this member (${memberName})";
    after = [
      "incus.service"
      "network-online.target"
    ];
    requires = [ "incus.service" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = lib.getExe bootstrapScript;
      # tailscale0 may carry no address yet at first boot, and on an itinerant fleet "not yet" is a
      # normal state rather than a fault — so retry instead of failing the boot.
      Restart = "on-failure";
      RestartSec = "10s";
    };
  };

  systemd.services.incus-cluster-roles = lib.mkIf isBootstrap {
    description = "Reconcile + assert Incus cluster member roles (itinerant members stay out of the raft)";
    after = [ "incus-cluster-bootstrap.service" ];
    requires = [ "incus.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = lib.getExe rolesScript;
      # A member that has not joined yet is not a fault, but a member that joined as a VOTER is —
      # and it must keep being retried, because the join can happen long after this host booted.
      Restart = "on-failure";
      RestartSec = "30s";
    };
  };
}
