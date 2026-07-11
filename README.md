## Git hooks

Enable the formatting check on commits:

1. Point Git at the hook directory: `git config core.hooksPath .githooks`.
2. Commits will now run `nix fmt -- --fail-on-change` via [.githooks/pre-commit](.githooks/pre-commit). If it fails, run `nix fmt` to apply fixes.
