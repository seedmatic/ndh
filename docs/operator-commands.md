# Operator Commands (@codebase)

This document defines the canonical operator-facing command model.

## Principles

- Internal implementation scripts can remain colocated with modules.
- Operator entrypoints are exposed as short commands from Nix packages/apps.
- Canonical operator command prefix is `ndh-`.
- Avoid exposing internal `io-nxmatic-*` script names in `bin/`.

## Canonical Commands

- `ndh-bringup-install`
  - Purpose: install/refresh the NDH bringup runtime profile.
  - Flake app/package attribute: `ndh-bringup-install`.

- `ndh-vm-lima-materialize`
  - Purpose: materialize Lima VM config and image links in the host profile.
  - Flake app/package attribute: `ndh-vm-lima-materialize`.

- `ndh-vm-tart-materialize`
  - Purpose: materialize Tart raw/ASIF image links in the host profile.
  - Flake app/package attribute: `ndh-vm-tart-materialize`.

## Darwin Configuration Selectors (@codebase)

For each host, Darwin outputs expose one selected default plus explicit VM flavor variants:

- `{host}`
  - Selected default Darwin configuration.
  - Provider is controlled by `hosts/<host>/default.nix` via `hostProfile.vmProvider`.

- `{host}-lima`
  - Explicit Darwin configuration aligned with Lima runtime (`<host>-nixos-lima`).

- `{host}-tart`
  - Explicit Darwin configuration aligned with Tart runtime (`<host>-nixos-tart`).

Examples:

- `bioskop`
- `bioskop-lima`
- `bioskop-tart`

## Migration Rules

1. Add/keep internal scripts under module-local `*.d/` folders.
2. Expose only stable wrappers as operator commands.
3. Name wrappers with short, task-oriented names (`ndh-<domain>-<action>`).
4. Prefer one operator tool surface over per-script ad-hoc names.

## Follow-up Candidates

- `ndh-ssh-keys-enrich`
