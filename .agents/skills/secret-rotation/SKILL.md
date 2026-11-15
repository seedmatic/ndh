---
name: secret-rotation
description: Rotate sops-encrypted secrets in ndh: edit, re-encrypt, propagate, and verify no plaintext leaks. Use when a secret expires, a key is compromised, or a new host joins.
---

# Secret Rotation (ndh)

Manage sops-encrypted secrets safely.

## When to use

- Rotating API keys, tokens, SSH keys, or certificates.
- Adding a new host/user to the sops recipient list.
- Investigating a suspected plaintext leak.

## Procedure

1. Edit the secret file: `sops .secrets` (or the relevant `*.yaml`).
2. Add/remove recipients: `sops updatekeys .secrets`.
3. Re-encrypt all managed files: `sops -i` or the rekey script in `modules/.common.d/sops.d/rekey.d/`.
4. Verify no plaintext remains: `grep` for key markers is insufficient; run the pre-commit guards.
5. Rebuild affected hosts: `nixos-rebuild switch` / `darwin-rebuild switch`.
6. Confirm services restart and new secrets take effect.

## Guards

- `.githooks/pre-commit` refuses private keys and token shapes in staged blobs.
- `sops_filter_attribute_guard` refuses sops filters in flake repos.
- `clear_secret_leaf_guard` refuses secret-named leaves in the clear.

## Pitfalls

- `encrypted_comment_regex` means leaves without `# sops:encrypted` stay plaintext.
- A valid sops envelope can still wrap an unencrypted payload.
- Never evaluate a decrypted checkout with nix.
- Keep `.sops.yaml` creation rules aligned with file paths.

## Related

- `host-provision`, `nix-rebuild`, `network-debug`.
