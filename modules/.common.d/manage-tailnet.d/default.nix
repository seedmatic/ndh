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
      routeApprovers = builtins.listToAttrs (
        map (cidr: {
          name = cidr;
          value = [ (tg t.kind.nixos) ];
        }) (baremetalCidrs ++ lanCidrs)
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
        # LAN-fixed baremetal.  A tag'd node's netmap only carries a subnet
        # route it is ACL-permitted to reach, so without these CIDRs a
        # console host loses the segments/LAN it had as an untagged member
        # (autogroup:members → *:*).
        {
          action = "accept";
          src = [ (tg t.role.console) ];
          dst = [
            "${tg t.role.console}:*"
            "${tg t.role.headless}:*"
          ]
          ++ map (cidr: "${cidr}:*") (baremetalCidrs ++ lanCidrs);
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
  }
)
