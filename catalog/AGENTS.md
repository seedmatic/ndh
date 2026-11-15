# catalog

## OVERVIEW
Configuration catalog: nix expressions + yaml metadata, trust statements, user mappings.

## STRUCTURE
*.nix, *.yaml, *.json, *.hujson, .statement, .sig files.

## WHERE TO LOOK
| Task | Location |
|------|----------|
| User mapping | *.nix |
| Trust statements | *.statement, *.sig |
| Cache config | cache-trust.yaml |
| Private caches | private-caches.json |

## CONVENTIONS
- Catalog drives ndh.context.catalog.
- Trust statements signed (.sig).

## ANTI-PATTERNS
- Don't edit signed statements without re-signing.
## NOTES
- Signed statements use .sig sidecars.
- Catalog consumed by ndh.context.
- YAML for metadata, nix for logic.
- No secrets in catalog.
