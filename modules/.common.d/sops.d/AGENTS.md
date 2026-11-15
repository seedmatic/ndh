# modules/.common.d/sops.d

## OVERVIEW
Sops bootstrap/rekey/looks-encrypted helpers.

## STRUCTURE
bootstrap.sh, rekey.d/rekey.sh, looks-encrypted.nix, tests/.

## WHERE TO LOOK
| Task | Location |
|------|----------|
| Bootstrap | bootstrap.sh |
| Rekey | rekey.d/rekey.sh |
| Encrypted check | looks-encrypted.nix |
| Tests | tests/, rekey.d/tests/ |

## CONVENTIONS
- Secrets via sops-nix; never commit plaintext.
- xtrace-guarded for private material.

## ANTI-PATTERNS
- Don't edit flake.lock by hand.
- Don't commit plaintext secrets.
- Don't rekey without validation.

## NOTES
- Used by bootstrap and rekey flows.
- Tests run via nix flake check.
- Verified against scan reports and spot-checked code.
- Run nix flake check after changes.
