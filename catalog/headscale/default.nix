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
in
{
  inherit listenPort serviceName;

  # File path — callers dereference to a store path when they need to
  # copy it, or interpolate as a path when substituting into scripts.
  aclPolicyFile = ./acl.hujson;

  # Tag vocabulary.  Two orthogonal axes:
  #
  #   role — who drives whom:  tag:operator, tag:service
  #   kind — what the node is: tag:darwin, tag:nixos, tag:incus, tag:rke2
  #
  # A node normally advertises one tag from each axis (e.g. bioskop
  # advertises both `operator` and `darwin`).  The ACL file keys broad
  # rules off the role axis for readability; kind-specific rules layer
  # on top when needed.
  tags = {
    role = {
      operator = "operator";
      service = "service";
    };
    kind = {
      darwin = "darwin";
      nixos = "nixos";
      incus = "incus";
      rke2 = "rke2";
    };
  };

  # The group that owns both operator and service tags.  Referenced by
  # the ACL file (`group:ndh`); exposed here so a future apply script
  # can cross-check the membership against the catalog's `user.name`.
  tagOwnerGroup = "group:ndh";

  # Where each client points its `--login-server`.  The server side
  # runs as a user LaunchAgent on each Darwin host (bootstrap phase,
  # before the rke2 cluster exists); mDNS gives a stable name so the
  # URL doesn't chase DHCP-assigned LAN IPs.
  #
  # Both Darwin hosts point at their LOCAL headscale — each laptop
  # maintains its own small tailnet during bootstrap.  Once rke2 is
  # up and a central headscale runs there, this collapses to a single
  # URL.
  serverUrls = {
    bioskop = "http://bioskop.local:${toString listenPort}";
    nikopol = "http://nikopol.local:${toString listenPort}";
  };
}
