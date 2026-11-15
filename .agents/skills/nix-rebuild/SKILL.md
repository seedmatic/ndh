---
name: nix-rebuild
description: Rebuild NixOS/Darwin hosts with ndh conventions, diagnose failures, and roll back safely. Use when applying config changes, debugging rebuild errors, or reverting a bad activation.
---

# Nix Rebuild (ndh)

Apply configuration changes and recover from bad activations.

## When to use

- After editing modules/hosts/catalog/inventory.
- A host is out of date with develop.
- An activation failed and needs diagnosis or rollback.

## Commands

```sh
nix flake check
nixos-rebuild switch --flake .#<host>-nixos
darwin-rebuild switch --flake .#<host>
nixos-rebuild switch --rollback
darwin-rebuild --rollback
```

## Diagnose

- Read the full activation log; identify the first failing unit or script.
- Check `journalctl -u <unit>` (NixOS) or `log show` (Darwin).
- Verify sops decryption and secret material before rebuild.
- Confirm the flake evaluates: `nix flake check` and `nix eval .#nixosConfigurations.<host>.config.system.build.toplevel`.

## Rollback

- NixOS: `nixos-rebuild switch --rollback` or select a previous generation at boot.
- Darwin: `darwin-rebuild --rollback`.
- If the store path is missing, use `nix-env --rollback` or a known good commit.

## Pitfalls

- Formatter check runs in `.githooks/pre-commit`; missing nix skips formatting, never guards.
- A decrypted checkout must not be evaluated with `nix build` (secret leak risk).
- Commit tracked changes before `nix flake check --no-build` sees them.
- aarch64-linux formatter may be unavailable; use `--no-verify` only when documented.

## Related

- `host-provision`, `secret-rotation`, `fleet-status`.
