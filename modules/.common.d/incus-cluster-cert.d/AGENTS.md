# modules/.common.d/incus-cluster-cert.d

## OVERVIEW
Incus cluster certificate renewal: incus-cluster-cert-renew, sans.nix, package, tests.

## STRUCTURE
incus-cluster-cert-renew.sh, sans.nix, package.nix, tests/.

## WHERE TO LOOK
| Task | Location |
|------|----------|
| CLI | incus-cluster-cert-renew.sh |
| SAN set | sans.nix |
| Tests | tests/ |

## CONVENTIONS
- Decrypts authority private only at signature.
- xtrace-guarded for private material.

## ANTI-PATTERNS
- Don't leak private keys.
- Don't bypass SAN set.

## NOTES
- Cluster cert renewal surface.
- Tests run via nix flake check.
- Verified against scan reports and spot-checked code.
- Run nix flake check after changes.
- Run nix flake check after changes.
- Run nix flake check after changes.
