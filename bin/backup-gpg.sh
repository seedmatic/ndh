#!/usr/bin/env bash
# Backup GPG keys and configuration
set -euo pipefail

BACKUP_DIR="${1:-$HOME/gpg-backup-$(date +%Y%m%d-%H%M%S)}"

echo "Creating GPG backup in: $BACKUP_DIR"
mkdir -p "$BACKUP_DIR"

# Export all keys (public and secret)
echo "Exporting public keys..."
gpg --export --armor > "$BACKUP_DIR/public-keys.asc"

echo "Exporting secret keys..."
gpg --export-secret-keys --armor > "$BACKUP_DIR/secret-keys.asc"

echo "Exporting secret subkeys..."
gpg --export-secret-subkeys --armor > "$BACKUP_DIR/secret-subkeys.asc"

# Export ownertrust
echo "Exporting trust database..."
gpg --export-ownertrust > "$BACKUP_DIR/ownertrust.txt"

# Backup GPG configuration
echo "Backing up GPG configuration..."
if [ -d "$HOME/.gnupg" ]; then
  tar -czf "$BACKUP_DIR/gnupg-config.tar.gz" -C "$HOME" .gnupg \
    --exclude='.gnupg/S.*' \
    --exclude='.gnupg/*.lock' \
    --exclude='.gnupg/random_seed'
fi

# Backup password store
echo "Backing up password store..."
if [ -d "$HOME/.password-store" ]; then
  tar -czf "$BACKUP_DIR/password-store.tar.gz" -C "$HOME" .password-store
fi

echo ""
echo "✅ Backup complete: $BACKUP_DIR"
echo ""
echo "Files created:"
ls -lh "$BACKUP_DIR"
echo ""
echo "To restore on another machine, run:"
echo "  ./restore-gpg.sh $BACKUP_DIR"
