# modules/.common.d/keyring.d

## OVERVIEW
Keyring CLI: host-key, vz-recover-key, cluster-age, age-key, public variants; tests.

## STRUCTURE
package.nix, ndh-keyring.sh, gen-ed25519.py, seedmatic-recipient.nix, tests/.

## WHERE TO LOOK
| Task | Location |
|------|----------|
| CLI | ndh-keyring.sh |
| Recipient | seedmatic-recipient.nix |
| Key gen | gen-ed25519.py |
| Tests | tests/ |

## CONVENTIONS
- Pass store under seedmatic/.
- Recipient pinned to seedmatic subkey.
- Private never in argv/output.
- Never overwrite existing entries.
- Validate inventory membership.

## ANTI-PATTERNS
- Don't let recipient be overridden by env.
- Don't overwrite keyring entries.
- Don't leak private material.

## NOTES
- Security-sensitive.
- Tests run via nix flake check.