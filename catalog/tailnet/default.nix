# Tailnet catalog — the control-plane identity of the fleet, independent
# of which controller enrolls the nodes.
#
# Two concerns live here:
#
#   tags / tagOwnerGroup — the shared `(role, kind)` tag vocabulary.
#     Controller-AGNOSTIC: a `tag:headless,tag:nixos` node has the same
#     identity whether it registers via Tailscale SaaS or self-hosted
#     Headscale.  Consumed by the client wiring (tag advertising), the
#     nixos/darwin outputs, and modules/.common.d/manage-tailnet.d (which
#     mints one per-kind auth key carrying that kind's tag pair).
#
#   aclPolicyFile — the HEADSCALE control plane's access policy (HuJSON).
#     NOT controller-agnostic, whatever this header used to say: the live
#     SaaS policy is GENERATED (`tailnetAclCanonical` in
#     modules/.common.d/manage-tailnet.d/default.nix, rendered to
#     tailnet-acl-canonical.json and reconciled by
#     `manage-tailnet --sync-acl`), derives its CIDRs from this catalog,
#     and carries rules this file has never had.  acl.hujson's own header
#     withdrew the agnostic claim already — « NOT copies of one policy —
#     they are two control planes' policies, and only one is in force ».
#     Split the two halves: the tag vocabulary below IS shared (a
#     `tag:headless,tag:nixos` node has one identity whichever controller
#     enrolls it), the POLICY is per control plane.
#
#     ⚠️ This file is still hand-written and on the legacy `acls` block,
#     while the generated SaaS policy moved to `grants` (and the
#     reconciler `del(.acls)` so the two never union).  Converging it is
#     now possible rather than blocked: `grants` arrive in headscale
#     0.29.0 and the pin sits at 0.29.x, so the old reason to keep `acls`
#     here — a controller that could not read grants — has expired.
#
#   headscale — the self-hosted control-plane server's NETWORK identity
#     (listen port, mDNS alias, per-host URLs).  Only relevant when
#     `ndh.tailnetClient.controller = "headscale"`; the SaaS controller
#     needs none of it (login.tailscale.com is implicit).  Consumed by
#     modules/{darwin,nixos}/headscale-daemon.nix and the client wiring's
#     `--login-server` derivation.
#
# Headscale policy lifecycle today is manual (`headscale policy set -f
# <aclPolicyFile>`), executed once against the running server (not yet
# packaged in this flake — see the launchd-daemon follow-up on bioskop).
let
  # The port the LaunchAgent binds.  41841 sits next to Tailscale's
  # own IANA-assigned 41641 (UDP WireGuard), making the port choice
  # self-documenting for anyone who recognises the Tailscale
  # numbering neighbourhood; unassigned by any well-known protocol,
  # so conflicts are unlikely.  Mirrored into /etc/services by the
  # Darwin headscale module so `lsof -iTCP -sTCP:LISTEN | grep 41841`
  # renders "headscale-bootstrap" rather than an anonymous port
  # number.
  listenPort = 41841;
  serviceName = "headscale-bootstrap";
  # Control plane alias.  All clients use the public DuckDNS domain,
  # which works universally (on-LAN via NAT hairpinning, off-LAN via
  # WAN). The Bbox port forward (WAN:41841 → bioskop:41841) routes
  # traffic to the headscale daemon. During Phase B (production),
  # update to point to K8s ingress or service IP.
  aliasName = "mammoth-skate.duckdns.org";
in
{
  # Tag vocabulary.  Two orthogonal axes:
  #
  #   role — who drives whom:  tag:console, tag:headless
  #   kind — what the node is: tag:darwin, tag:nixos
  #
  # A node normally advertises one tag from each axis (e.g. bioskop
  # advertises both `console` and `darwin`).  The ACL file keys broad
  # rules off the role axis for readability; kind-specific rules layer
  # on top when needed.
  #
  # Role vocabulary names the host's physical access pattern:
  #   console  — a human sits at this host's keyboard / screen.
  #              Workstations, laptops, admin terminals.
  #   headless — no local console; reachable only remotely.
  #              Servers, VMs, containers, cluster nodes.
  # That axis is what the ACL actually gates on (who originates
  # admin SSH vs only accepts it), so the tags read true regardless
  # of operating system.
  tags = {
    role = {
      console = "console";
      headless = "headless";
    };
    # This vocabulary is exactly the set of kinds ndh MINTS AN AUTH KEY FOR (one per entry, paired
    # with a role tag), and therefore also the set it CLAIMS in `tagOwners`. So a tag registered by
    # something else must not appear here — see `tag:k8s` in acl.hujson.
    #
    # `incus` and `rke2` were removed on 2026-09-27: no device ever carried either. Incus containers
    # are not tailnet members (only the operator's proxies are), and cluster devices are registered
    # by the Tailscale operator as `tag:k8s`, a name the chart defaults to and we do not own.
    kind = {
      darwin = "darwin";
      nixos = "nixos";
    };
  };

  # The group that owns every role + kind tag.  Referenced by
  # the ACL file (`group:ndh`); exposed here so a future apply script
  # can cross-check the membership against the catalog's `user.name`.
  tagOwnerGroup = "group:ndh";

  # Tailnet access policy (HuJSON).  Controller-agnostic — see the module
  # header.  Callers dereference to a store path to copy it, or interpolate
  # as a path when substituting into scripts / API payloads.
  aclPolicyFile = ./acl.hujson;

  # Self-hosted Headscale control-plane NETWORK identity.  SaaS ignores
  # all of this (see the module header).
  headscale = {
    inherit listenPort serviceName aliasName;

    # Fleet-scoped alias that every client's `--login-server` points at.
    # The host currently holding `services.headscaleBootstrap.role =
    # "primary"` publishes `aliasName` via mDNS (see
    # packages/ndh-mdns-publish) so resolution follows ownership
    # transparently: when the operator promotes nikopol by flipping
    # roles, clients stay on the same URL and simply hit a different
    # host's IP.  Exactly one host should be `primary` at any time.
    aliasUrl = "https://${aliasName}:${toString listenPort}";
  };
}
