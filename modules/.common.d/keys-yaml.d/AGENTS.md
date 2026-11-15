# modules/.common.d/keys-yaml.d

## OVERVIEW
keys.yaml trust/schema tooling: trusted/compromised slots, phase-2 gate, KRL, recipients.

## STRUCTURE
trust.nix, slots.nix, keys-json.sh, json-tool.nix, krl.sh, recipients, tests/.

## WHERE TO LOOK
| Task | Location |
|------|----------|
| Trust slots | trust.nix (trustedSlots, compromisedSlots, phase2Gaps) |
| Host-key slots | slots.nix (current/pending) |
| Public view | keys-json.sh, json-tool.nix |
| KRL builder | krl.sh |
| Recipients | keyring-recipient.nix, operator-recipient.nix |
| Tests | tests/ |

## CONVENTIONS
- Nix helpers expose one definition per feature.
- Secrets never pass through argv/output.
- xtrace guards for private material.

## ANTI-PATTERNS
- Don't trust a pending slot as current.
- Don't regenerate host keys while present.
- Don't leak private material to traces.

## NOTES
- Handles private material; high-risk.
- Tests run via nix flake check.