# Shared tailnet-secret schema.  Both Tailscale (SaaS tailnet) and
# Headscale (self-hosted tailnet) expose the same pair of credentials:
#
#   auth — node-registration key (`tskey-auth-…` / `hskey-auth-…`).
#          Long-lived-ish bearer token a joining client presents once
#          with `tailscale up --authkey=…`; subsequent re-registrations
#          use the node's own keypair.  Headscale v2 binds the
#          advertised tag set to the preauth key itself (clients can't
#          assert tags on an authkey flow); the key IS the tag
#          contract.  Because kind-specific nodes (darwin operator,
#          nixos service, …) need different tag pairs, we mint one
#          auth key per kind rather than sharing a "fleet" key.
#   api  — admin control-plane token (`tskey-api-…` / `hskey-api-…`).
#          Used by tooling that manages users, nodes, preauth keys via
#          the HTTP/gRPC API instead of the local unix socket.  One
#          per service; scope-neutral.  On Tailscale SaaS it is legacy:
#          the `client` OAuth secret below supersedes it (API keys can't
#          self-rotate; an OAuth client is long-lived and mints both the
#          short-lived API token and the per-kind auth keys).
#   client — Tailscale SaaS OAuth client secret (`tskey-client-…`).
#          Tailscale-only, tailnet-wide (no per-kind split).  Long-lived
#          (no 90-day expiry), used ONLY by the operator's rotation
#          tooling (scripts/rotate-tailnet-secrets) — never materialised
#          on a node.  It exchanges for a short-lived API token that
#          mints the per-kind `auth` keys.
#
# Both live in the flake's `.secrets`:
#
#   tailnet:
#     tailscale:
#       client: ENC[…]     # OAuth client secret — mints the auth keys below
#       auth:
#         darwin: ENC[…]   # tag:console,tag:darwin
#         nixos:  ENC[…]   # tag:headless,tag:nixos
#         incus:  ENC[…]   # tag:headless,tag:incus (minted when needed)
#         rke2:   ENC[…]   # tag:headless,tag:rke2  (minted when needed)
#       api:  ENC[…]       # legacy admin key — superseded by `client`
#     headscale:
#       auth:
#         darwin: ENC[…]   # tag:console,tag:darwin
#         nixos:  ENC[…]   # tag:headless,tag:nixos
#         incus:  ENC[…]   # tag:headless,tag:incus (minted when needed)
#         rke2:   ENC[…]   # tag:headless,tag:rke2  (minted when needed)
#       api: ENC[…]
#
# This module is the single source of truth for that schema.  It owns
# no behaviour on its own — it declares a canonical sops.secrets entry
# for each credential the caller opts into, and exposes the runtime
# path so Darwin LaunchAgents and NixOS systemd units consume the same
# filesystem contract.  Platform-specific wiring (who starts the
# daemon, how activation scripts read the secret) belongs in
# modules/darwin/ and modules/nixos/.
{
  config,
  lib,
  worktreePath,
  ...
}:

with lib;

let
  cfg = config.tailnet;

  # Which kinds the per-kind auth tree exposes slots for — the SAME set
  # for both services (tailscale + headscale), since a node's `(role,
  # kind)` tag pair is controller-agnostic.  Every kind corresponds to a
  # distinct tag pair — see catalog/tailnet/acl.hujson.
  authKinds = [
    "darwin"
    "nixos"
    "incus"
    "rke2"
  ];

  # Keep secret pathnames on disk identical to the `.secrets` YAML
  # path — operator reading `/run/secrets/nix-darwin-home/...` sees
  # the same word shape as when editing with `sops .secrets`.
  secretNamespaceDir = "/run/secrets/nix-darwin-home";
  # name(service, slotPath) -> "tailnet.<service>.<slot…>"
  #   slotPath is a list of strings, e.g. ["auth"] or ["auth" "darwin"].
  namespace = service: slotPath: "tailnet.${service}." + concatStringsSep "." slotPath;
  secretPath = service: slotPath: "${secretNamespaceDir}/${namespace service slotPath}";
  sopsPath = service: slotPath: "tailnet/${service}/" + concatStringsSep "/" slotPath;

  # Canonical credential-leaf submodule.  One of these per concrete
  # secret the schema exposes.  The `slotPath` argument is purely
  # used to derive default paths / sops-key lookup for this leaf.
  credentialSubmodule =
    { service, slotPath }:
    types.submodule {
      options = {
        enable = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Materialise the `${service}` ${concatStringsSep "." slotPath} secret
            from `${cfg.sopsEncryptedFile}` at `${secretPath service slotPath}`.
          '';
        };
        sopsKey = mkOption {
          type = types.str;
          default = sopsPath service slotPath;
          description = ''
            Key path inside the sops YAML.  Defaults mirror the
            canonical `tailnet.${service}.${concatStringsSep "." slotPath}`
            layout; override only if a caller stores the key under a
            non-standard path.
          '';
        };
        path = mkOption {
          type = types.path;
          default = secretPath service slotPath;
          readOnly = true;
          description = ''
            Runtime filesystem path of the decrypted secret.  Consumer
            modules (headscale client, tailscale autoconnect) read
            from here after sops-install-secrets has materialised it.
          '';
        };
        owner = mkOption {
          type = types.str;
          default = config.profile.user.name;
          description = ''
            Unix user that owns the decrypted secret.  Defaults to the
            profile user so operator-shell consumers (hs-connect, the
            `hs` admin wrapper) can read it without sudo.  NixOS
            platform modules that hand the file to a system daemon
            should override this to `root` in their own module.
          '';
        };
        mode = mkOption {
          type = types.str;
          default = "0400";
          description = "File permissions for the decrypted secret.";
        };
      };
    };

  # Per-kind `auth` tree, parameterized by service.  Both Tailscale (SaaS)
  # and Headscale mint ONE auth key per kind, each scoped to that kind's
  # `(role, kind)` tag pair.  The key carries the tags — headscale binds
  # them to the preauth key; SaaS binds them at mint time via the API — so
  # no client-asserted `--advertise-tags` is needed on either controller.
  authKindsSubmodule =
    service:
    types.submodule {
      options = listToAttrs (
        map (kind: {
          name = kind;
          value = mkOption {
            type = credentialSubmodule {
              inherit service;
              slotPath = [
                "auth"
                kind
              ];
            };
            default = { };
            description = ''
              ${service} auth key scoped to the `${kind}` kind of node,
              carrying the matching tag pair (`tag:console,tag:darwin` for
              `darwin`, `tag:headless,tag:<kind>` for every other kind).
            '';
          };
        }) authKinds
      );
    };

  # Tailscale (SaaS): per-kind `auth` keys + one long-lived `client` OAuth
  # secret that mints them.
  tailscaleSubmodule = types.submodule {
    options = {
      auth = mkOption {
        type = authKindsSubmodule "tailscale";
        default = { };
        description = "Per-kind node-registration auth keys (tskey-auth-…).";
      };
      client = mkOption {
        type = credentialSubmodule {
          service = "tailscale";
          slotPath = [ "client" ];
        };
        default = { };
        description = ''
          OAuth client secret (tskey-client-…).  Long-lived (no 90-day
          expiry); used ONLY by scripts/rotate-tailnet-secrets to mint the
          per-kind `auth` keys.  Never materialised on a node — leave
          `enable = false`.
        '';
      };
    };
  };

  # Headscale (self-hosted): per-kind `auth` keys + a single `api` admin key.
  headscaleSubmodule = types.submodule {
    options = {
      auth = mkOption {
        type = authKindsSubmodule "headscale";
        default = { };
        description = "Per-kind pre-auth keys (hskey-auth-…).";
      };
      api = mkOption {
        type = credentialSubmodule {
          service = "headscale";
          slotPath = [ "api" ];
        };
        default = { };
        description = "Admin API key (hskey-api-…).";
      };
    };
  };

  # Enumerate every concrete credential leaf in the schema.  Each entry
  # carries the slotPath used to build names + sops keys and a pointer to
  # the option leaf so we can read `.enable`, `.sopsKey`, `.path`, etc.
  # without re-deriving them.
  authLeaves =
    service:
    map (kind: {
      inherit service;
      slotPath = [
        "auth"
        kind
      ];
      leaf = cfg.${service}.auth.${kind};
    }) authKinds;

  allLeaves =
    authLeaves "tailscale"
    ++ authLeaves "headscale"
    ++ [
      {
        service = "tailscale";
        slotPath = [ "client" ];
        leaf = cfg.tailscale.client;
      }
      {
        service = "headscale";
        slotPath = [ "api" ];
        leaf = cfg.headscale.api;
      }
    ];

  enabledLeaves = filter (e: e.leaf.enable) allLeaves;

  mkSecretAttrs = e: {
    name = namespace e.service e.slotPath;
    value = {
      format = "yaml";
      sopsFile = cfg.sopsEncryptedFile;
      key = e.leaf.sopsKey;
      path = e.leaf.path;
      owner = e.leaf.owner;
      mode = e.leaf.mode;
    };
  };
in
{
  options.tailnet = {
    sopsEncryptedFile = mkOption {
      type = types.path;
      default = (worktreePath.of ".secrets");
      description = ''
        Path to the sops-encrypted YAML carrying the `tailnet.*` tree.
        Defaults to the flake-tracked `.secrets`; override only when a
        caller lives outside the repo root (tests, integration
        harnesses).
      '';
    };

    tailscale = mkOption {
      type = tailscaleSubmodule;
      default = { };
      description = "Tailscale (SaaS) credentials.";
    };

    headscale = mkOption {
      type = headscaleSubmodule;
      default = { };
      description = "Headscale (self-hosted) credentials.";
    };
  };

  config = mkIf (enabledLeaves != [ ]) {
    sops.secrets = listToAttrs (map mkSecretAttrs enabledLeaves);
  };
}
