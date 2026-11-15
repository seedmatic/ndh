# modules/.common.d/keys-reconcile.d

## OVERVIEW
Operator key rotation window: plan, declare, retire, close; artifact classes (host-key, attic-cache-key).

## STRUCTURE
keys-reconcile.sh, declare.sh, close.sh, retire.sh, verify.sh, write.sh, package.nix, classes/, tests/.

## WHERE TO LOOK
| Task | Location |
|------|----------|
| CLI entry | keys-reconcile.sh |
| Declare | declare.sh |
| Retire | retire.sh, retire-key |
| Close | close.sh |
| Verify | verify.sh |
| Write | write.sh |
| Classes | classes/attic-cache-key.sh |
| Tests | tests/ |

## CONVENTIONS
- Revision frozen at eval (F5); batch frozen.
- Armed via ndh-ops delegation (root-owned, unexpired).
- Single operator `yes` on tty; one local commit, never pushed.
- Encrypted values stay byte-identical (only recipient/MAC stanzas move).

## ANTI-PATTERNS
- Never run without arming.
- Never push the commit.
- Never re-encrypt a whole sops file.
- Never reuse a public.
- Never declare a second rotation while one in flight.
- Never close/revoke by serial via krl (exact key id only).

## NOTES
- High-risk sops mutation.
- Tests run via nix flake check.