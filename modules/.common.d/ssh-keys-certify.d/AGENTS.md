# modules/.common.d/ssh-keys-certify.d

## OVERVIEW
Operator seat certificate signer: ssh-keys-certify [--apply].

## STRUCTURE
ssh-keys-certify.sh, host-names.nix, package.nix, tests/.

## WHERE TO LOOK
| Task | Location |
|------|----------|
| CLI | ssh-keys-certify.sh |
| Host names | host-names.nix |
| Tests | tests/certify.bats, tests/host-names.nix |

## CONVENTIONS
- Reads keys.yaml in clear (only privates encrypted).
- Dry run by default; --apply decrypts one authority slot's private into ssh-agent, signs, records via sops set.

## ANTI-PATTERNS
- Never sign an ssh-host key not named after a machine.
- Never leave a private unencrypted.
- Never show sops stderr (may quote plaintext).

## NOTES
- Certificate signing and comparison.
- Tests run via nix flake check.
- Verified against scan reports and spot-checked code.
- Run nix flake check after changes.
- Run nix flake check after changes.
