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
{
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

  # Per-host server URL.  Where each client points its `--login-server`.
  # Today both Darwin hosts read this via `hostProfile.headscaleServerUrl`
  # in their host profile; wiring them through the catalog is a
  # follow-up cleanup.
  serverUrls = {
    bioskop = "http://192.168.5.10:8080";
    nikopol = "http://192.168.1.193:8080";
  };
}
