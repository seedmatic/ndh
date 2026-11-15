# catalog

## OVERVIEW
Configuration catalog: nix expressions + yaml metadata, trust statements, user mappings.

## STRUCTURE
*.nix, *.yaml, *.json, *.hujson, .statement, .sig files; tailnet/, private-caches.d/.

## WHERE TO LOOK
| Task | Location |
|------|----------|
| User/machine mapping | machines.nix |
| Trust statements | *.statement, *.sig, private-caches.d/statements/ |
| Cache config | cache-trust.nix, cache-trust.yaml |
| Private caches | private-caches.nix, private-caches.json |
| Netplan/segments | default.nix (netplan) |
| Tailnet ACL | tailnet/default.nix, tailnet/acl.hujson |
| Merge helpers | merge.nix |

## CONVENTIONS
- Catalog drives ndh.context.catalog.
- Trust statements signed (.sig).
- YAML for metadata, nix for logic.
- No secrets in catalog.

## ANTI-PATTERNS
- Don't edit signed statements without re-signing.
- Don't park inactive substituters in cache-trust.nix.
- Don't advertise home LAN CIDR in tailnet routes.

## NOTES
- Signed statements use .sig sidecars.
- Catalog consumed by ndh.context.
- Derived addresses come from catalog/blueprint.
- private-caches.d/ has tests and statements.
