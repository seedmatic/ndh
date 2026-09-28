# `manage-tailnet` — administer the Tailscale SaaS tailnet via the long-lived
# OAuth client: rotate per-kind auth keys, reconcile the ACL, retag devices, and
# prune stale (orphaned) devices.  Safe by default (dry-run).  Script:
# modules/.common.d/manage-tailnet.d/manage-tailnet.sh.
#
# Exposed BOTH as the `manage-tailnet` flake app (`nix run .#manage-tailnet`) and
# as `packages.<system>.manage-tailnet` — the latter so a consumer (flox env,
# another flake's runtimeInputs) can put it on PATH.  The flake is the single
# source of truth for this wiring, so the recipe lives here once and both the
# apps and packages outputs import it (like bbox-reconcile).
#
# Inputs
#   - `catalog.tailnet.tags`        — per-kind + role tag vocabulary (baked into
#                                     the auth-key request bodies + the ACL)
#   - `catalog.netplan.baremetal`   — subnet-router advertised CIDRs (ACL route
#                                     auto-approvers)
#     (`catalog.netplan.lan.cidr` is NOT an input any more — the home LAN is neither
#      approved nor granted here; see the ⚠️ note above `routeApprovers`)
#   - `catalog.netplan.segments`    — cluster segments; the "vmnet" /18 supernet is
#                                     auto-approved for tag:nixos, the BARE-METAL that
#                                     owns each vmnet bridge having replaced the
#                                     per-cluster operator Connector as its announcer.
#                                     Each cluster's `*-net` gateway also serves as the
#                                     in-supernet probe for the policy's `tests`
#   - `ndhStore.installBinScript`   — the bash-trampoline bin wrapper
#   - `nixBashTrampoline`           — the shared nix-managed bash + logger + env
#   - `withCommit`                  — pin git for `--commit`, or leave it out (see below)
{
  pkgs,
  catalog,
  ndhStore,
  nixBashTrampoline,
  # `--commit` git-commits .secrets after a rotation, and pinning git costs **1540 MiB of closure**
  # (measured 2026-09-26: git pulls python3, clang and the apple-sdk), against ~60 MiB for everything
  # else this script needs.  A caller that only READS the tailnet therefore builds with false — the
  # Tart materializer does, since its bundle is `nix copy`'d to a vz-host and was designed to stay
  # around 50-100 MiB.  Not an arbitrary switch: `--commit` requires a checkout to commit INTO, and
  # the preflight already refuses it alongside `--secrets-file`, so the two are exclusive by nature.
  withCommit ? true,
}:
let
  # Kinds + tag pairs are baked from catalog.tailnet.tags so the script needs no
  # runtime `nix eval`.  90-day expiry = the auth-key maximum.
  tailnetAuthKindsSpec =
    let
      t = catalog.tailnet.tags;
      pair =
        k:
        if k == "darwin" then
          [
            t.role.console
            t.kind.${k}
          ]
        else
          [
            t.role.headless
            t.kind.${k}
          ];
    in
    map (
      k:
      let
        tags = map (x: "tag:" + x) (pair k);
      in
      {
        inherit tags;
        kind = k;
        # Full Tailscale POST /keys request body, built here so the
        # script only reads/extracts JSON with yq-go (no runtime JSON
        # construction).
        body = {
          capabilities.devices.create = {
            reusable = true;
            ephemeral = false;
            preauthorized = true;
            inherit tags;
          };
          expirySeconds = 7776000;
          description = "ndh ${k} per-kind auth key";
        };
      }
    ) (builtins.attrNames t.kind);
  tailnetAuthKindsFile = pkgs.writeText "tailnet-auth-kinds.json" (
    builtins.toJSON tailnetAuthKindsSpec
  );
  # Canonical Tailscale-SaaS ACL fragment, built from the catalog.  The
  # `--sync-acl` reconcile merges this into the LIVE tailnet policy
  # (preserving personal/k8s tags, nodeAttrs, and existing routes;
  # pruning the superseded operator/service/container tags).
  #
  # OAuth-client tag ownership follows the Tailscale-recommended pattern
  # (kb/1215/oauth-clients): a dedicated owner tag — assigned to the
  # rotation OAuth client in the console — owns the per-kind tags, so the
  # client may mint keys carrying them.  The legacy `acls` block is still
  # what we emit, but its REASON HAS EXPIRED: it was kept so this tag
  # vocabulary stayed usable by the headscale controller, which does not
  # understand `grants` — and headscale is hibernating, its policy file a
  # separate artefact nothing syncs.  Migrating is decided, not done (see
  # docs/network-topology-c4.adoc#authorisation): it must `del(.acls)` in
  # sync_acl in the SAME change, because the effective policy is the
  # permissive UNION of both blocks — a canonical `.grants` alone would be
  # dropped by the reconciler while the superseded `acls` kept granting.
  # `ssh` uses `accept` per the single-operator rationale in
  # catalog/tailnet/acl.hujson.
  tailnetAclCanonical =
    let
      t = catalog.tailnet.tags;
      tg = x: "tag:" + x;
      ownerTag = "tag:tailnet-key-owner";
      ourTags = [
        t.role.console
        t.role.headless
      ]
      ++ builtins.attrValues t.kind;
      bm = catalog.netplan.baremetal or { };
      # The aggregate CIDR each baremetal host advertises into the tailnet.
      baremetalCidrs = map (h: bm.${h}.advertiseCidr) (
        builtins.filter (h: bm.${h} ? advertiseCidr) (builtins.attrNames bm)
      );
      # ⚠️ `netplan.lan.cidr` is DELIBERATELY ABSENT from both families below, and the
      # absence must survive refactors.  Advertising the home LAN cost an outage on
      # 2026-09-27 (see the ⚠️ note in modules/nixos/baremetal-segment.nix: an accepter
      # sitting ON that LAN has its connected route displaced by the tunnel, leaving an
      # asymmetric path where only the SYN-ACK survives).  Dropping the advertisement
      # alone was NOT enough, which is why the CIDR is gone from here too: approval and
      # permission are the other two conditions, and both were still armed — the /24 was
      # auto-approved for `tag:nixos`, so ANY re-advertisement, deliberate or regressed,
      # would have been approved with NO console step and reached by every `tag:console`
      # peer.  With `acceptRoutes = true` now on both NixOS hosts, the next victim was
      # nikopol coming home onto that same LAN.
      #
      # Restoring off-site reach to the home LAN is not a matter of putting this back: it
      # needs the prefix withheld from peers that SIT on it, hence a tag distinguishing
      # LAN-FIXED from ROAMING hosts, where tags are minted per KIND and shared by every
      # host of that kind.  A vocabulary change — and Tailscale Services reach a screen
      # without installing any route at all (docs/network-topology-c4.adoc#authorisation).
      #
      # The cluster vmnet supernet (/18) the tailscale-operator's `controlplane`
      # Connector advertises as a subnet route: every cluster's kube-vip VIP
      # (10.80.<w>.10) and LB span live inside it, so the management cluster's
      # CAPI reaches a workload apiserver THROUGH the tailnet (see rke2lab
      # docs/architecture/cluster-api/management-workload-topology.adoc
      # #cp-endpoint-reach).  Published by rke2lab's blueprint as the segment
      # named "vmnet" (NetplanBlueprintScenario) — derived here, never hardcoded.
      vmnetCidrs = map (s: s.cidr) (
        builtins.filter (s: (s.name or "") == "vmnet") (catalog.netplan.segments or [ ])
      );
      # ONE approver tag for both families, because one kind of device advertises both: the
      # bare-metal's NixOS host — its own fabric slice, and, since the vmnet subnet-router role
      # moved off the operator's `Connector` pod onto the host that owns the bridges (see
      # modules/nixos/cluster-vmnet.nix), the cluster segments too. The vmnet family was mapped
      # to `tag:k8s` for exactly as long as a Connector advertised it; leaving it there would
      # have left every cluster segment PENDING approval forever.
      routeApprovers = builtins.listToAttrs (
        map (cidr: {
          name = cidr;
          value = [ (tg t.kind.nixos) ];
        }) (baremetalCidrs ++ vmnetCidrs)
      );

      # Tailscale SERVICES (catalog.netplan.tailnet.services) — see that block for why they
      # replace routing the home LAN.  Two policy facts they need, both derived:
      tailnetServices = catalog.netplan.tailnet.services or { };
      serviceNames = builtins.attrNames tailnetServices;
      uniq =
        xs:
        builtins.attrNames (
          builtins.listToAttrs (
            map (x: {
              name = x;
              value = null;
            }) xs
          )
        );
      # An advertiser name -> the KIND tag it carries, by the SAME convention
      # `--retag-devices` applies: `<host>` is the bare Mac (darwin), `<host>-<kind>` is that
      # kind.  Unknown suffixes fail the evaluation rather than defaulting, since a service
      # approved for the wrong tag is a service that never leaves PENDING.
      advertiserTag =
        name:
        let
          m = builtins.match "[^-]+-(.+)" name;
        in
        tg (if m == null then t.kind.darwin else t.kind.${builtins.head m});
      # ★ A service host must be TAGGED, and the service must be auto-approved for the tag
      # its advertisers carry — otherwise it sits PENDING admin approval for ever.  Exactly
      # the "approver follows the advertiser" rule the routes above obey; it has already cost
      # us one silent stall this week, on the vmnet family.
      serviceApprovers = builtins.listToAttrs (
        map (n: {
          name = "svc:${n}";
          value = uniq (map advertiserTag tailnetServices.${n}.advertisers);
        }) serviceNames
      );
      # ★ Operator seats that are NOT tailnet members.  A vz-host declared `foreign` is a
      # corp-managed Mac that cannot join the tailnet (VPN binaries are not allowed on it),
      # yet it is the operator's primary seat for the shared screens — so it must be able to
      # REACH a service even though it can never carry a tag.
      #
      # Its segment address is the identity, because there is no NAT anywhere: a packet
      # forwarded by the subnet router keeps `vzHostAddress` as its source, which is not a
      # tailnet identity, so `src = tag:console` alone drops it.  `src` accepting a bare IP
      # or CIDR is exactly the vendor's mechanism for traffic originating behind a subnet
      # router.  Measured 2026-09-27 that only this rule was missing: the corp Mac already
      # routes `100.64.0.0/10` via its link (baremetal-link), every service VIP falls inside
      # that /10, and the reply path is live — bioskop holds `172.16.16/20 -> utun0` and
      # reaches `172.16.24.2` today.
      offTailnetOperatorSeats = map (h: bm.${h}.vzHostAddress) (
        builtins.filter (h: (bm.${h}.vzHostKind or "") == "foreign") (builtins.attrNames bm)
      );
      # Every service here is operator-facing, so one src list covers them all — including
      # the bbox, since the seat that needs a screen is the seat that needs the router's UI.
      # A service is named in `dst` WITH its prefix; unlike a subnet route it needs no CIDR,
      # and unlike a tag it grants no reach to the advertiser's own addresses.
      serviceGrants = map (n: {
        src = [ (tg t.role.console) ] ++ offTailnetOperatorSeats;
        dst = [ "svc:${n}" ];
        ip = tailnetServices.${n}.ip;
      }) serviceNames;
      # `tests` wants an `ip:port`, and a service accepts `svc:<name>:<port>` — so the
      # reachability of every service is assertable, and the control plane refuses a policy
      # that would drop one.
      serviceProbes = builtins.concatMap (
        n: map (e: "svc:${n}:${builtins.head (builtins.match "[a-z]+:([0-9]+)" e)}") tailnetServices.${n}.ip
      ) serviceNames;
      # Concrete in-family addresses for the `tests` block below.  A test asserts an
      # `ip:port`, and a CIDR is not one — so the families above cannot be tested by
      # their prefix, only through an address that sits inside them.  All derived:
      # `netGateway`/`vzHostAddress` for each bare-metal slice, and — since the
      # `vmnet` segment declares no `hosts` — each cluster's own `*-net` gateway,
      # which lives inside the `/18` supernet the ACL actually names.
      segmentProbes =
        builtins.concatMap (
          h: [ bm.${h}.netGateway ] ++ (if bm.${h} ? vzHostAddress then [ bm.${h}.vzHostAddress ] else [ ])
        ) (builtins.attrNames bm)
        ++ map (s: s.gateway) (
          builtins.filter (s: (s ? gateway) && builtins.match ".*-(mgmt|wrkld)-net" (s.name or "") != null) (
            catalog.netplan.segments or [ ]
          )
        );
    in
    {
      tagOwners = {
        ${ownerTag} = [ "autogroup:admin" ];
      }
      // builtins.listToAttrs (
        map (x: {
          name = tg x;
          value = [ ownerTag ];
        }) ourTags
      );
      # `grants`, not the legacy `acls` block.  Two reasons, and the second is why this
      # is not merely a modernisation:
      #
      #  1. The `acls` block was kept so this tag vocabulary stayed readable by the
      #     headscale controller, which does not understand grants.  Headscale is
      #     hibernating and its policy is a separate artefact nothing syncs, so that
      #     coupling is gone.
      #  2. ★ A `grants` block was ALREADY LIVE and ungoverned — measured 2026-09-27,
      #     mirroring these rules but frozen on `172.16.6.0/24` / `172.16.7.0/24`, the
      #     pre-renumbering fabric segments, which designate nothing since 2026-09-23.
      #     Nothing in this repo emitted it, so it cannot be a stale generation of this
      #     file: it was written by hand or by the console's ACL-to-grants conversion.
      #     The effective policy being the permissive UNION of both blocks, it granted
      #     reach nobody was reviewing.  Emitting grants here is what puts it under the
      #     catalog; `sync_acl` replaces it and deletes `acls` in one move.
      #
      # Shape differs from `acls`: there is no `action`, the port leaves `dst` for `ip`,
      # so `"tag:x:*"` becomes dst `"tag:x"` + `ip = ["*"]`.  A mistranslation would be
      # invisible in review, which is what the `tests` block below exists to catch.
      grants = [
        # Trusted owner devices (untagged members: laptop, phone) reach
        # everything.  Tagged fleet nodes below stay role-segmented.
        # `autogroup:member` is the documented spelling and the plural is a legacy alias
        # for the same set, so this is a rename — but ⚠️ the two MAY NOT COEXIST in one
        # policy.  Measured 2026-09-27, the POST was rejected outright: "ACLs contain a
        # mix of old-style autogroup:members and new-style autogroup:member; use one or
        # the other."  It is therefore a whole-policy property, not a per-rule choice:
        # the `ssh` block below had to move in the same change, and anything preserved
        # from the live policy must be checked before adding a rule here.
        {
          src = [ "autogroup:member" ];
          dst = [ "*" ];
          ip = [ "*" ];
        }
        # Operator (console) hosts reach the whole fleet by role tag AND
        # the per-baremetal segments (vzhost.<domain> + the Incus instances
        # behind each subnet router) AND the cluster vmnet supernet (kube-vip VIPs /
        # apiservers, advertised since 2026-09-27 by the BARE-METAL that owns
        # each vmnet bridge — see modules/nixos/cluster-vmnet.nix — not by a
        # per-cluster operator Connector, which rke2lab no longer renders).
        # A tag'd node's netmap only carries a subnet route it is ACL-permitted
        # to reach, so without these CIDRs a console host loses the
        # segments/LAN/VIPs it had as an untagged member (autogroup:member →
        # *).  The supernet entry is what keeps this independent of which
        # /21s exist: a new cluster needs no ACL change.
        {
          src = [ (tg t.role.console) ];
          dst = [
            (tg t.role.console)
            (tg t.role.headless)
          ]
          ++ baremetalCidrs
          ++ vmnetCidrs;
          ip = [ "*" ];
        }
        # Headless nodes reach each other AND each other's segments. The CIDRs are what makes
        # `acceptRoutes` mean anything host-to-host: a node installs only the routes it is
        # ACL-permitted to reach, so without them the reciprocal-gateway design is a no-op — the
        # routes arrive in the netmap and are dropped.
        #
        # ⚠️ Measured 2026-09-27, and it cost the milestone: `nikopol-mgmt`'s kube-vip was up and
        # `bioskop-nixos` had ZERO route to `10.80.16.0/21`, so `ip route get 10.80.23.10` fell
        # through to the home gateway and CAPI's RemoteConnectionProbe timed out — the cluster read
        # `Degraded` with every pool `Adopted`. The failure is silent by construction: the route is
        # advertised, approved, and simply never installed.
        #
        # ★ Not the tailscale OPERATOR's job. An in-cluster egress would dial the same subnet-routed
        # address and hit this same rule, and a pod-advertised route dies with its cluster — which is
        # why the per-cluster `Connector` was removed earlier the same day. Routing belongs to the
        # hosts; this rule is what lets them do it.
        {
          src = [ (tg t.role.headless) ];
          dst = [
            (tg t.role.headless)
          ]
          ++ baremetalCidrs
          ++ vmnetCidrs;
          ip = [ "*" ];
        }
        # The Tailscale operator's own devices inside a cluster (funnel / ingress
        # proxies).  They carry `tag:k8s` and NO role-axis tag, so neither rule
        # above reaches them: measured 2026-09-27, `bioskop-mgmt-flux-webhook` and
        # its three siblings answer the public internet through Funnel while being
        # absent from every fleet node's netmap — a posture nobody chose.
        #
        # Named as a dst rather than fixed by making the operator stamp a role tag:
        # `tag:k8s` is the operator CHART's default, owned by ITS OAuth client, and
        # a dst may reference a tag without owning it.  Claiming it in tagOwners
        # would take that ownership away and stop the operator registering devices
        # at all (the reconcile merges `live * canonical`, canonical winning).
        {
          src = [ (tg t.role.console) ];
          dst = [ "tag:k8s" ];
          ip = [ "*" ];
        }
        # The reverse direction, and the one that makes an in-cluster EGRESS possible: a
        # `tag:k8s` device reaching the fleet's segments.  Measured 2026-09-28 from inside
        # `egress-0` of a `ProxyGroup type: egress` — a real tailnet device, `tailscale0` up
        # at 100.97.76.24 — everything on its OWN bare-metal answers and everything on the
        # PEER fails, regardless of destination kind:
        #
        #     172.16.0.1:8443   (own fabric/incus)  OK
        #     10.80.7.10:6443   (own vmnet VIP)     OK
        #     172.16.16.1:8443  (peer fabric)       fail
        #     10.80.23.10:6443  (peer vmnet VIP)    fail
        #
        # Which places the failure here and nowhere else: the rule widened on 2026-09-27
        # named `tag:headless` — the bare-metals — so the hosts route to each other's
        # segments while a cluster device carries no tag this policy admits as a source.
        # That is the whole of why `ClusterIntention/nikopol-mgmt` reads `Degraded` while
        # the operator's own kubeconfig reaches the very same VIP: a kubeconfig runs on a
        # tailnet member, CAPI's RemoteConnectionProbe runs in a POD.
        #
        # ⚠️ `tag:k8s` as a SRC without owning it. Naming it as a `dst` is established
        # above, and claiming it in `tagOwners` is ruled out there (it would stop the
        # operator registering devices at all). Whether `src` is equally permissive is NOT
        # verified — it cannot be tested without POSTing a policy, which is the operator's
        # move. If it is refused, the refusal is LOUD: `sync_acl` POSTs the whole document
        # and the API rejects it with a message, exactly as it did for the
        # autogroup:members mix. A silent half-application is not a failure mode here.
        #
        # Least privilege on purpose: the CIDRs only, no role tag in `dst`. The relay needs
        # the peer's SEGMENTS (subnet-routed traffic is filtered on the destination
        # address), never a conversation with the bare-metal itself.
        {
          src = [ "tag:k8s" ];
          dst = baremetalCidrs ++ vmnetCidrs;
          ip = [ "*" ];
        }
      ]
      ++ serviceGrants;
      ssh = [
        # Console (operator admin) hosts SSH the entire fleet.  Every
        # fleet node carries a role tag, so [console, headless] covers
        # them all.  (SSH dst permits only tags + autogroup:self — not
        # autogroup:member; untagged member devices aren't SSH targets.)
        {
          action = "accept";
          src = [ (tg t.role.console) ];
          dst = [
            (tg t.role.console)
            (tg t.role.headless)
          ];
          users = [
            "autogroup:nonroot"
            "root"
          ];
        }
        # Headless nodes SSH each other (nix copy, node-to-node ops).
        {
          action = "accept";
          src = [ (tg t.role.headless) ];
          dst = [ (tg t.role.headless) ];
          users = [
            "autogroup:nonroot"
            "root"
          ];
        }
        # Member devices reach their own devices.
        {
          action = "accept";
          src = [ "autogroup:member" ];
          dst = [ "autogroup:self" ];
          users = [
            "autogroup:nonroot"
            "root"
          ];
        }
      ];
      autoApprovers = {
        routes = routeApprovers;
        # Darwin hosts are the sanctioned exit nodes: bioskop (home
        # baremetal) always provides public egress; nikopol (roaming)
        # shares its uplink on demand — e.g. tethered to a phone
        # hotspot it becomes the tailnet's gateway to the public net.
        # Auto-approve their exit-node advertisements (no console step).
        exitNode = [ (tg t.kind.darwin) ];
        services = serviceApprovers;
      };
      # ★ The policy carries its OWN assertions, and the control plane REFUSES the POST
      # when one fails ("If an assertion fails, Tailscale rejects the updated tailnet
      # policy file").  So this block is not documentation — it is the gate that stops a
      # later edit of this file from widening or narrowing reach unnoticed, starting with
      # the pending `acls` -> `grants` translation, where ports leave `dst` for `ip` and a
      # mistranslation would be invisible in review.  A test's `src` may be a TAG and its
      # `accept`/`deny` may name `tag:<name>:<port>`, so the role segmentation is
      # assertable directly rather than through device addresses.
      tests = [
        {
          src = tg t.role.console;
          accept = [
            "${tg t.role.console}:5900" # the operator's own screens
            "${tg t.role.headless}:22"
            "tag:k8s:443" # named without owning the tag — see the grants comment
          ]
          ++ map (ip: "${ip}:22") segmentProbes
          ++ serviceProbes;
        }
        {
          src = tg t.role.headless;
          # A node must reach its PEER's segments — that is what makes `acceptRoutes` mean
          # anything host-to-host, and what CAPI's RemoteConnectionProbe rides to reach a
          # child cluster's apiserver.
          #
          # ★ These moved from `deny` to `accept` on 2026-09-27, and the move was FORCED
          # rather than chosen: widening the grant alone made the control plane reject the
          # POST with "test(s) failed", because this block still asserted the old posture.
          # That is the gate working — an intent cannot drift from a rule in silence, and
          # closing the gap had to be stated here in the same change.
          accept = [
            "${tg t.role.headless}:22"
          ] # nix copy, node-to-node ops
          ++ map (ip: "${ip}:22") segmentProbes;
          # Still asserted in the direction a mistake would WIDEN: role segmentation holds,
          # a headless node has no business on an operator console.
          deny = [ "${tg t.role.console}:5900" ];
        }
      ];
    };
  tailnetAclCanonicalFile = pkgs.writeText "tailnet-acl-canonical.json" (
    builtins.toJSON tailnetAclCanonical
  );

  # The tailnet's SPLIT-DNS map: each per-baremetal DNS zone resolved by that segment's own Incus
  # dnsmasq.  `{ "<domain>": [ "<netGateway>" ] }`, derived from the same catalog entries the route
  # auto-approvers come from.
  #
  # This was the last tailnet fact still typed into the console, and the cost was visible: the same
  # `netGateway` is consumed by three resolvers — this one, `modules/darwin/baremetal-resolvers.nix`
  # (`/etc/resolver/<domain>` on each nix-managed Mac) and `pkgs/baremetal-link.d/install.sh` (the
  # same file on a foreign vz-host).  Two of the three were already generated, so when the fabric
  # slices were renumbered on 2026-09-23 those two corrected themselves at the next rebuild while
  # the authoritative one kept pointing at a retired resolver.  A hand-typed copy of a derived fact
  # does not drift slowly; it drifts the moment the fact changes.
  # Desired Tailscale SERVICE definitions, consumed by `--sync-services`.  A service must
  # EXIST in the tailnet before any node may advertise it, and the vendor documents that
  # step as admin-console-only — measured FALSE on 2026-09-27:
  # `/api/v2/tailnet/-/vip-services` answers 200 and has a per-service path (a bogus path
  # 404s with a different body).  So service definition stays declarative alongside the
  # other four control-plane operations instead of becoming the one console step.
  #
  # ★ `annotations` marks OWNERSHIP, and that is what makes pruning safe: the reconcile
  # deletes only services carrying this marker, so anything created by the tailscale
  # k8s-operator — or by hand — is reported and left alone.  The live list is empty today,
  # so nothing is at stake yet; the marker is here so it never becomes a question.
  #
  # `addrs` is deliberately ABSENT: Tailscale auto-allocates the pair on create, and the
  # vendor's own client warns that a later update omitting them ERRORS.  Carrying them
  # forward is the reconcile's job, not the catalog's.
  tailnetServicesCanonical =
    let
      svcs = catalog.netplan.tailnet.services or { };
    in
    map (n: {
      name = "svc:${n}";
      ports = svcs.${n}.ip;
      comment = "ndh: catalog.netplan.tailnet.services.${n} — advertised by ${
        builtins.concatStringsSep ", " svcs.${n}.advertisers
      }";
      annotations = {
        "io.seedmatic.ndh/managed" = "true";
      };
    }) (builtins.attrNames svcs);
  tailnetServicesFile = pkgs.writeText "tailnet-services-canonical.json" (
    builtins.toJSON tailnetServicesCanonical
  );
  tailnetSplitDnsFile = pkgs.writeText "tailnet-split-dns.json" (
    builtins.toJSON (
      builtins.listToAttrs (
        # Every per-baremetal zone, resolved by that segment's own dnsmasq …
        map (host: {
          name = catalog.netplan.baremetal.${host}.domain;
          value = [ catalog.netplan.baremetal.${host}.netGateway ];
        }) (builtins.attrNames (catalog.netplan.baremetal or { }))
        # … plus the home LAN's own zone, resolved by the site router. It was the one zone live in
        # the tailnet that this map did not declare, so a reconcile would have reported it as
        # "extra" forever. It is load-bearing: it is what makes `<host>.lan` resolve for a tailnet
        # peer, which is the out-of-band path to a foreign vz-host (see pkgs/baremetal-link.d).
        # `lan.domain` carries a leading dot (".lan") because other consumers concatenate it; the
        # API key is the bare zone.
        ++ [
          {
            name =
              let
                d = catalog.netplan.lan.domain;
              in
              # builtins only, like the rest of this module (no `lib` in scope here).
              if builtins.substring 0 1 d == "." then builtins.substring 1 (builtins.stringLength d - 1) d else d;
            value = [ catalog.netplan.lan.gateway ];
          }
        ]
      )
    )
  );
in
# Bash-trampoline pattern: source the shared trampoline (nix-managed bash +
# logger + stable env), pin every tool by absolute store path (@sops@/@curl@/@yq@
# — yq-go only, no jq), and bake the kinds + ACL canonical files in.
ndhStore.installBinScript "manage-tailnet" (
  pkgs.replaceVars ./manage-tailnet.sh {
    nixBashTrampoline = nixBashTrampoline;
    loggerTag = "ndh.manage-tailnet";
    sops = "${pkgs.sops}/bin/sops";
    curl = "${pkgs.curl}/bin/curl";
    yq = "${pkgs.yq-go}/bin/yq";
    # Empty when excluded, so the closure never reaches git; the preflight turns that into a clear
    # refusal if --commit is asked of such a build, rather than an obscure "command not found".
    git = if withCommit then "${pkgs.git}/bin/git" else "";
    authKinds = tailnetAuthKindsFile;
    aclCanonical = tailnetAclCanonicalFile;
    servicesCanonical = tailnetServicesFile;
    splitDns = tailnetSplitDnsFile;
  }
)
