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
#   - `catalog.netplan.lan.cidr`    — the home LAN a LAN-fixed baremetal advertises
#   - `catalog.netplan.segments`    — cluster segments; the "vmnet" /18 supernet is
#                                     auto-approved for tag:k8s (operator Connector
#                                     advertises each cluster's kube-vip VIP in it)
#   - `ndhStore.installBinScript`   — the bash-trampoline bin wrapper
#   - `nixBashTrampoline`           — the shared nix-managed bash + logger + env
{
  pkgs,
  catalog,
  ndhStore,
  nixBashTrampoline,
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
  # client may mint keys carrying them.  We keep the legacy `acls` block
  # (not `grants`) so the same tag vocabulary stays usable by the
  # headscale controller too; `ssh` uses `accept` per the single-operator
  # rationale in catalog/tailnet/acl.hujson.
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
      # A LAN-fixed baremetal's subnet router also advertises the whole home
      # LAN (see baremetal-segment.nix); auto-approve it for the same nixos tag.
      lanCidrs =
        if builtins.any (h: (bm.${h}.lanAttachment or "roaming") == "fixed") (builtins.attrNames bm) then
          [ catalog.netplan.lan.cidr ]
        else
          [ ];
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
      routeApprovers = builtins.listToAttrs (
        (map (cidr: {
          name = cidr;
          value = [ (tg t.kind.nixos) ];
        }) (baremetalCidrs ++ lanCidrs))
        # vmnet routes are advertised by the operator's Connector device, which
        # the operator stamps `tag:k8s` — NOT tag:nixos (the baremetal host subnet
        # routers).  A different approver tag, so a separate mapping.
        ++ (map (cidr: {
          name = cidr;
          value = [ (tg "k8s") ];
        }) vmnetCidrs)
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
      acls = [
        # Trusted owner devices (untagged members: laptop, phone) reach
        # everything.  Tagged fleet nodes below stay role-segmented.
        {
          action = "accept";
          src = [ "autogroup:members" ];
          dst = [ "*:*" ];
        }
        # Operator (console) hosts reach the whole fleet by role tag AND
        # the per-baremetal segments (vzhost.<domain> + the Incus instances
        # behind each subnet router) AND the fixed home LAN advertised by a
        # LAN-fixed baremetal AND the cluster vmnet supernet (kube-vip VIPs /
        # apiservers advertised by the operator Connector).  A tag'd node's
        # netmap only carries a subnet route it is ACL-permitted to reach, so
        # without these CIDRs a console host loses the segments/LAN/VIPs it had
        # as an untagged member (autogroup:members → *:*).
        {
          action = "accept";
          src = [ (tg t.role.console) ];
          dst = [
            "${tg t.role.console}:*"
            "${tg t.role.headless}:*"
          ]
          ++ map (cidr: "${cidr}:*") (baremetalCidrs ++ lanCidrs ++ vmnetCidrs);
        }
        {
          action = "accept";
          src = [ (tg t.role.headless) ];
          dst = [ "${tg t.role.headless}:*" ];
        }
      ];
      ssh = [
        # Console (operator admin) hosts SSH the entire fleet.  Every
        # fleet node carries a role tag, so [console, headless] covers
        # them all.  (SSH dst permits only tags + autogroup:self — not
        # autogroup:members; untagged member devices aren't SSH targets.)
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
          src = [ "autogroup:members" ];
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
      };
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
    git = "${pkgs.git}/bin/git";
    authKinds = tailnetAuthKindsFile;
    aclCanonical = tailnetAclCanonicalFile;
    splitDns = tailnetSplitDnsFile;
  }
)
