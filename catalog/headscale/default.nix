# Headscale tailnet catalog — shared policy + tag vocabulary + per-host
# server URLs.  Consumed by:
#
#   - modules/darwin/headscale.nix        (client config: login-server, tags)
#   - modules/nixos/tailscale.nix         (NixOS guest client config)
#   - a future bootstrap daemon module    (loads aclPolicyFile on start)
#
# Policy lifecycle today is manual:
#
#     headscale policy set -f <aclPolicyFile>
#
# executed once against the running headscale server (which does not
# yet live in this flake — see follow-up issue for the launchd-daemon
# packaging on bioskop).  Tag advertising on clients is already wired
# through this module; a re-register picks up the `operator` / `service`
# names.
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
  inherit listenPort serviceName aliasName;

  # File path — callers dereference to a store path when they need to
  # copy it, or interpolate as a path when substituting into scripts.
  aclPolicyFile = ./acl.hujson;

  # Tag vocabulary.  Two orthogonal axes:
  #
  #   role — who drives whom:  tag:console, tag:headless
  #   kind — what the node is: tag:darwin, tag:nixos, tag:incus, tag:rke2
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
    kind = {
      darwin = "darwin";
      nixos = "nixos";
      incus = "incus";
      rke2 = "rke2";
    };
  };

  # The group that owns every role + kind tag.  Referenced by
  # the ACL file (`group:ndh`); exposed here so a future apply script
  # can cross-check the membership against the catalog's `user.name`.
  tagOwnerGroup = "group:ndh";

  # Per-host physical URL — falls back to each host's local mDNS name
  # when the `aliasUrl` below is unreachable.  Currently unused by
  # clients (they read `aliasUrl`) but retained for diagnostics and
  # for the rare case where an operator wants to point at a specific
  # physical instance instead of the alias.
  serverUrls = {
    bioskop = "https://bioskop.local:${toString listenPort}";
    nikopol = "https://nikopol.local:${toString listenPort}";
  };

  # Fleet-scoped alias that every client's `--login-server` points at.
  # The host currently holding `services.headscaleBootstrap.role =
  # "primary"` publishes `aliasName` via mDNS (see
  # packages/ndh-mdns-publish) so resolution follows ownership
  # transparently: when the operator promotes nikopol by flipping
  # roles, clients stay on the same URL and simply hit a different
  # host's IP.  Exactly one host should be `primary` at any time.
  # `aliasName` itself is inherited from the `let` block above.
  aliasUrl = "https://${aliasName}:${toString listenPort}";
}
