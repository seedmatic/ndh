# nfsd-off — no Mac of the fleet serves NFS (docs: sshfs replaced the NFS /net automount in 2e5bb326).
#
#   nfsd-off <exports file>
#
# ndh 2e5bb326 deleted the module that wrote /etc/exports and ran `nfsd enable`, and nix-darwin
# undoes nothing: the exports outlived it, and macOS restarts nfsd at boot while /etc/exports exists.
# So this moves the file aside — root-only, dated, never deleted — disables the service and stops it,
# then checks: nfsd still enabled or running fails the activation loudly. It touches no exported data.

exports="${1:?usage: nfsd-off <exports file>}"
# /sbin last: a test puts its stand-in first.
PATH="$PATH:/sbin"

if [ -e "$exports" ]; then
  aside="$exports.ndh-disabled-$(date -u +%Y%m%dT%H%M%SZ)"
  install -m 0600 "$exports" "$aside"
  rm "$exports"
  echo "[nfsd-off] $exports moved aside to $aside: no NFS export remains"
fi

nfsd disable || true
if nfsd status 2>/dev/null | grep -q "is running"; then
  nfsd stop || true
fi

# `nfsd status` exits 0 while the service is enabled.
if nfsd status >/dev/null 2>&1; then
  echo "[nfsd-off] ERROR: nfsd is still ENABLED after \`nfsd disable\`" >&2
  exit 1
fi
if nfsd status 2>/dev/null | grep -q "is running"; then
  echo "[nfsd-off] ERROR: nfsd is still RUNNING after \`nfsd stop\`" >&2
  exit 1
fi
echo "[nfsd-off] nfsd disabled and stopped"
