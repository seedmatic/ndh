# Fleet headscale admin CLI (`hs`) built via writeShellApplication
# — single binary, git-style subcommand dispatcher:
#
#   hs check                  read-only reconcile .secrets ↔ server
#   hs mint [--force] KIND…   mint missing preauth keys + sops write-back
#   hs <anything else>        forwarded to `headscale` with the right
#                             admin transport (unix socket on the
#                             primary host, gRPC-over-env elsewhere)
#
# The writeShellApplication wrapper bakes `set -euo pipefail` and
# runs shellcheck at build time, so syntax / lint errors surface on
# `darwin-rebuild switch` rather than at first invocation.
#
# Gated on `tailnet.headscale.api.enable` — only console hosts that
# opt into the admin API key get the package installed.  NixOS guests
# have no use for it and never see this module (it's only imported
# by modules/darwin/default.nix).
{
  config,
  lib,
  pkgs,
  ndh,
  self,
  ...
}:

let
  cfg = config.networking.headscale;
  tailnet = config.tailnet;

  headscaleToolsDir = "${self}/modules/darwin/headscale-tools";

  # Shared helpers inlined into the main script at build time.
  # writeShellApplication's shellcheck pass can't follow relative
  # `source` paths, so we substitute the library body verbatim via
  # pkgs.replaceVars and the @HS_LIB_INLINE@ marker.
  hsLibText = builtins.readFile "${headscaleToolsDir}/hs-lib.sh";

  apiKeyFile = tailnet.headscale.api.path;
  # `.secrets` is resolved at runtime inside `hs` (git rev-parse
  # --show-toplevel, or the NDH_SECRETS_FILE env override).  Baking
  # `${self}/.secrets` into the script would point at the immutable
  # nix-store snapshot — fine for reads, impossible for writes by
  # `hs mint`, which must land in the operator's worktree.
  expectedUser = config.profile.user.name or "nxmatic";
  # Default validity for minted preauth keys.  10y matches the
  # mammoth-skate CA's lifetime so a full re-key is a single sweep.
  mintExpiration = "10y";

  # Catalog's hardcoded tailnet IPs, baked into the script as a JSON
  # map so `hs verify-extra-records` can diff them against the live
  # `headscale node list`.  Source of truth is
  # catalog.netplan.tailnet.hosts.<key>.ip — same data the
  # extra_records renderer in
  # modules/{darwin,nixos}/headscale-daemon.nix consumes.
  expectedTailnetIpsJson = builtins.toJSON (
    lib.mapAttrs (_: hostSpec: hostSpec.ip)
      (ndh.context.catalog.netplan.tailnet.hosts or { })
  );

  # Default gRPC host:port for remote-admin mode.  Only consulted
  # when we can't reach the daemon via its local unix socket and
  # the operator didn't set HEADSCALE_CLI_ADDRESS by hand.  The
  # catalog alias is the obvious candidate; fall back to the
  # `hostname` option that headscale uses to advertise itself to
  # clients.
  hsHostname =
    let
      alias = ndh.context.catalog.headscale.aliasName or null;
    in
    if alias != null then alias else (cfg.hostname or "localhost");

  renderedHsSource = pkgs.replaceVars "${headscaleToolsDir}/hs.sh" {
    HS_LIB_INLINE = hsLibText;
    API_KEY_FILE = apiKeyFile;
    HEADSCALE_HOSTNAME = hsHostname;
    EXPECTED_USER = expectedUser;
    MINT_EXPIRATION = mintExpiration;
    EXPECTED_TAILNET_IPS_JSON = expectedTailnetIpsJson;
  };

  hsBin = pkgs.writeShellApplication {
    name = "hs";
    text = builtins.readFile renderedHsSource;
    runtimeInputs = [
      # Pinned to the same derivation the daemon uses (0.28.x via
      # nixpkgs-unstable) so CLI and server don't disagree on
      # policy-v2 shapes or preauth-key formats.  Defined in
      # modules/.common.d/headscale-pkg.nix.
      config.ndh.headscalePkg
    ]
    ++ (with pkgs; [
      yq-go
      sops
      coreutils
      # `hs` uses `git rev-parse --show-toplevel` to locate the
      # operator's .secrets in the flake worktree (the baked-in
      # nix-store snapshot is read-only, so we can't use it for
      # `hs mint`'s sops write-back).
      git
    ]);
  };
in
{
  options.ndh.headscaleTools = lib.mkOption {
    type = lib.types.package;
    readOnly = true;
    description = ''
      The `hs` admin CLI derivation.  Consumers that want an
      absolute path (e.g. activation hooks calling `hs check` under
      a timeout wrapper) read this instead of resolving via PATH.
    '';
  };

  config = lib.mkIf tailnet.headscale.api.enable {
    ndh.headscaleTools = hsBin;
    environment.systemPackages = [ hsBin ];
  };
}
