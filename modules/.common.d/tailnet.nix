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
#          per service; scope-neutral.
#
# Both live in the flake's `.secrets`:
#
#   tailnet:
#     tailscale:
#       auth: ENC[…]
#       api:  ENC[…]
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
  paths,
  ...
}:

with lib;

let
  cfg = config.tailnet;

  # Which kinds the headscale auth tree exposes slots for.  Every kind
  # corresponds to a distinct `(role, kind)` tag pair — see
  # catalog/headscale/acl.hujson.
  headscaleAuthKinds = [
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
  sopsPath =
    service: slotPath: "tailnet/${service}/" + concatStringsSep "/" slotPath;

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

  # Tailscale keeps the simple shape (one auth + one api scalar).
  tailscaleSubmodule = types.submodule {
    options = {
      auth = mkOption {
        type = credentialSubmodule {
          service = "tailscale";
          slotPath = [ "auth" ];
        };
        default = { };
        description = "Node-registration auth key (tskey-auth-…).";
      };
      api = mkOption {
        type = credentialSubmodule {
          service = "tailscale";
          slotPath = [ "api" ];
        };
        default = { };
        description = "Admin API key (tskey-api-…).";
      };
    };
  };

  # Headscale splits `auth` per kind — each kind mints a preauth key
  # scoped to exactly the `(role, kind)` tag pair that node should
  # register with.  `api` stays a single scalar.
  headscaleAuthSubmodule = types.submodule {
    options = listToAttrs (
      map (kind: {
        name = kind;
        value = mkOption {
          type = credentialSubmodule {
            service = "headscale";
            slotPath = [
              "auth"
              kind
            ];
          };
          default = { };
          description = ''
            Pre-auth key scoped to the `${kind}` kind of node.  Minted
            with the matching tag pair (`tag:console,tag:darwin` for
            `darwin`, `tag:headless,tag:<kind>` for every other kind)
            via `hs preauthkeys create`.
          '';
        };
      }) headscaleAuthKinds
    );
  };

  headscaleSubmodule = types.submodule {
    options = {
      auth = mkOption {
        type = headscaleAuthSubmodule;
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

  # Enumerate every concrete credential leaf in the schema.  Each
  # entry carries the slotPath used to build names + sops keys and a
  # pointer to the option leaf so we can read `.enable`, `.sopsKey`,
  # `.path`, etc. without re-deriving them.
  allLeaves =
    [
      {
        service = "tailscale";
        slotPath = [ "auth" ];
        leaf = cfg.tailscale.auth;
      }
      {
        service = "tailscale";
        slotPath = [ "api" ];
        leaf = cfg.tailscale.api;
      }
      {
        service = "headscale";
        slotPath = [ "api" ];
        leaf = cfg.headscale.api;
      }
    ]
    ++ map (kind: {
      service = "headscale";
      slotPath = [
        "auth"
        kind
      ];
      leaf = cfg.headscale.auth.${kind};
    }) headscaleAuthKinds;

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
      default = (paths.at ".secrets");
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
