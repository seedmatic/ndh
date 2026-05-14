# Shared tailnet-secret schema.  Both Tailscale (SaaS tailnet) and
# Headscale (self-hosted tailnet) expose the same pair of credentials:
#
#   auth — node-registration key (`tskey-auth-…` / `hskey-auth-…`).
#          Long-lived-ish bearer token a joining client presents once
#          with `tailscale up --authkey=…`; subsequent re-registrations
#          use the node's own keypair.
#   api  — admin control-plane token (`tskey-api-…` / `hskey-api-…`).
#          Used by tooling that manages users, nodes, preauth keys via
#          the HTTP/gRPC API instead of the local unix socket.
#
# Both live in the flake's `.secrets` under a symmetric tree:
#
#   tailnet:
#     tailscale:
#       auth: ENC[…]
#       api:  ENC[…]
#     headscale:
#       auth: ENC[…]
#       api:  ENC[…]
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
  self,
  ...
}:

with lib;

let
  cfg = config.tailnet;

  # Keep secret pathnames on disk identical to the `.secrets` YAML
  # path — operator reading `/run/secrets/nix-darwin-home/...` sees
  # the same word shape as when editing with `sops .secrets`.
  secretNamespaceDir = "/run/secrets/nix-darwin-home";
  namespace = service: kind: "tailnet.${service}.${kind}";
  secretPath = service: kind: "${secretNamespaceDir}/${namespace service kind}";
  sopsPath = service: kind: "tailnet/${service}/${kind}";

  # Ordered list of (service, kind) pairs the schema recognises; kept
  # as data so `config` can loop once and emit sops.secrets entries
  # without repeating the shape four times.
  entries = [
    {
      service = "tailscale";
      kind = "auth";
    }
    {
      service = "tailscale";
      kind = "api";
    }
    {
      service = "headscale";
      kind = "auth";
    }
    {
      service = "headscale";
      kind = "api";
    }
  ];

  # Build a nested `tailnet.<service>.{auth,api}` option tree.  Each
  # leaf is a submodule exposing:
  #   enable       — whether to materialise this secret at all
  #   sopsKey      — default 'tailnet/<service>/<kind>' (callers almost
  #                  never need to override)
  #   path         — readOnly runtime path (callers consume this)
  credentialSubmodule =
    { service, kind }:
    types.submodule {
      options = {
        enable = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Materialise the `${service}` ${kind} secret from
            `${cfg.sopsEncryptedFile}` at `${secretPath service kind}`.
          '';
        };
        sopsKey = mkOption {
          type = types.str;
          default = sopsPath service kind;
          description = ''
            Key path inside the sops YAML.  Defaults mirror the
            canonical `tailnet.${service}.${kind}` layout; override
            only if a caller stores the key under a non-standard path.
          '';
        };
        path = mkOption {
          type = types.path;
          default = secretPath service kind;
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

  serviceSubmodule =
    service:
    types.submodule {
      options = {
        auth = mkOption {
          type = credentialSubmodule {
            inherit service;
            kind = "auth";
          };
          default = { };
          description = "Node-registration auth key (tskey-auth-/hskey-auth-).";
        };
        api = mkOption {
          type = credentialSubmodule {
            inherit service;
            kind = "api";
          };
          default = { };
          description = "Admin API key (tskey-api-/hskey-api-).";
        };
      };
    };

  enabledEntries = lib.filter (e: cfg.${e.service}.${e.kind}.enable) entries;

  mkSecretAttrs =
    e:
    let
      leaf = cfg.${e.service}.${e.kind};
    in
    {
      name = namespace e.service e.kind;
      value = {
        format = "yaml";
        sopsFile = cfg.sopsEncryptedFile;
        key = leaf.sopsKey;
        path = leaf.path;
        owner = leaf.owner;
        mode = leaf.mode;
      };
    };
in
{
  options.tailnet = {
    sopsEncryptedFile = mkOption {
      type = types.path;
      default = "${self}/.secrets";
      description = ''
        Path to the sops-encrypted YAML carrying the `tailnet.*` tree.
        Defaults to the flake-tracked `.secrets`; override only when a
        caller lives outside the repo root (tests, integration
        harnesses).
      '';
    };

    tailscale = mkOption {
      type = serviceSubmodule "tailscale";
      default = { };
      description = "Tailscale (SaaS) credentials.";
    };

    headscale = mkOption {
      type = serviceSubmodule "headscale";
      default = { };
      description = "Headscale (self-hosted) credentials.";
    };
  };

  config = mkIf (enabledEntries != [ ]) {
    sops.secrets = lib.listToAttrs (map mkSecretAttrs enabledEntries);
  };
}
