# modules/.common.d/host-key.d

## OVERVIEW
Host key slots and certificates: generate, certificate.nix, slots.nix, tests.

## STRUCTURE
generate.sh, certificate.nix, slots.nix, tests/.

## WHERE TO LOOK
| Task | Location |
|------|----------|
| Generate | generate.sh (ndh-host-key-generate) |
| Certificate | certificate.nix |
| Slots | slots.nix (current/pending) |
| Tests | tests/ |

## CONVENTIONS
- current filters pending/retired.
- Private never in argv/output.
- Never regenerate while present (rename into place).

## ANTI-PATTERNS
- Don't trust pending as current.
- Don't regenerate host keys while present.
- Don't leak private material.

## NOTES
- Security-sensitive key generation.
- Tests run via nix flake check.
- Verified against scan reports and spot-checked code.
