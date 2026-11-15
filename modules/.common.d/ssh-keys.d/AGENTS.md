# modules/.common.d/ssh-keys.d

## OVERVIEW
SSH key enrichment/splitting and trusted user CA helpers.

## STRUCTURE
ssh-enrich-keys-yaml.sh, ssh-split-keys-yaml.sh, ssh-trusted-user-ca.sh, tests/.

## WHERE TO LOOK
| Task | Location |
|------|----------|
| Enrichment | ssh-enrich-keys-yaml.sh |
| Splitting | ssh-split-keys-yaml.sh |
| Trusted CA | ssh-trusted-user-ca.sh |
| Tests | tests/ |

## CONVENTIONS
- Runs under trampoline; v2 enrichment logic.
- TLS signing via step-cli; reviewed hop key::set_field.
- xtrace-guarded for private material.

## ANTI-PATTERNS
- Don't bypass enrichment hop.
- Don't leak private keys to traces.
- Don't trust guest keys beyond read-write sftp.

## NOTES
- Central enrichment unit depends on sops-install-secrets.
- Tests run via nix flake check.
- Verified against scan reports and spot-checked code.
