# modules/.common.d/manage-tailnet.d

## OVERVIEW
Tailnet ACL/services/split-DNS/auth-key generator (manage-tailnet package + flake app).

## STRUCTURE
default.nix (large generator), manage-tailnet.sh.

## WHERE TO LOOK
| Task | Location |
|------|----------|
| Generator | default.nix |
| CLI | manage-tailnet.sh |
| Policy source | catalog/tailnet/acl.hujson |

## CONVENTIONS
- Safe by default (dry-run).
- bash-trampoline with pinned tools.
- Inputs baked at eval time.
- withCommit optional (git closure cost).

## ANTI-PATTERNS
- Don't advertise home LAN CIDR in tailnet routes.
- Don't hardcode derived addresses.
- Don't run --commit without review.

## NOTES
- Canonical SaaS policy source; headscale policy hibernates.
- Run: nix run .#manage-tailnet.
- Verified against scan reports and spot-checked code.
