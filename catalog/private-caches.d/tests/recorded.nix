# Every entry of catalog/private-caches.json is what keys-reconcile verified, never a hand edit (R1, class
# attic-cache-key): its committed statement (private-caches.d/statements/attic-<ms>.cache-key.statement, .sig) names
# exactly this public's sha256, this cache and its guest, and verifies against that guest's RECORDED serving host key
# in keys.json, namespace seedmatic-attic. An entry without it, or with any field of it changed, is refused; so is a
# statement for a cache the file does not hold. The same check must refuse a forged entry, in the same build.
{
  pkgs,
  entries,
  forged,
  statements,
  # metalspace → the guest whose host key signs its cache's statement, and that key as keys.json records it
  signers,
}:
let
  inherit (pkgs) lib;
  rowsOf =
    set:
    lib.mapAttrsToList (ms: e: {
      inherit ms;
      inherit (e) publicKey;
      machine = (signers.${ms} or (throw "private-caches: no guest of ${ms} declares a cache")).machine;
      signer = signers.${ms}.public;
    }) set;
  table = rows: lib.concatMapStrings (r: "${r.ms}\t${r.machine}\t${r.signer}\t${r.publicKey}\n") rows;
in
pkgs.runCommand "private-caches-recorded"
  {
    nativeBuildInputs = [
      pkgs.coreutils
      pkgs.openssh
    ];
    real = table (rowsOf entries);
    forged = table (rowsOf forged);
    passAsFile = [
      "real"
      "forged"
    ];
  }
  ''
    # check <rows file>: 0 when every row is backed by its verified statement and no statement is left over
    check() {
      local fail=0 ms machine signer public s sum held=" "
      while IFS=$'\t' read -r ms machine signer public; do
        held+="$ms "
        s=${statements}/attic-$ms.cache-key
        if [ ! -f "$s.statement" ] || [ ! -f "$s.statement.sig" ]; then
          echo "privateCaches.$ms: no committed statement: the entry was not written by keys-reconcile" >&2; fail=1; continue
        fi
        sum=$(printf '%s\n' "$public" | sha256sum | cut -d' ' -f1)
        [ "$(cat "$s.statement")" = "$(printf 'seedmatic-attic v1\nclass attic-cache-key\ncache %s\nmachine %s\nsha256 %s' "$ms" "$machine" "$sum")" ] ||
          { echo "privateCaches.$ms: its statement does not name this public, this cache and $machine" >&2; fail=1; continue; }
        printf 'host-%s %s\n' "$machine" "$signer" >allowed
        ssh-keygen -q -Y verify -f allowed -I "host-$machine" -n seedmatic-attic -s "$s.statement.sig" <"$s.statement" >/dev/null 2>&1 ||
          { echo "privateCaches.$ms: its statement is not signed by $machine's recorded host key" >&2; fail=1; }
      done <"$1"
      for f in ${statements}/*.statement; do
        [ -e "$f" ] || continue
        ms=$(basename "$f" .cache-key.statement); ms=''${ms#attic-}
        case "$held" in *" $ms "*) ;; *) echo "a committed statement for $ms, which the entries do not hold" >&2; fail=1 ;; esac
      done
      return $fail
    }
    check "$realPath" || { echo "FAIL catalog/private-caches.json holds an entry keys-reconcile did not verify" >&2; exit 1; }
    if check "$forgedPath" 2>/dev/null; then echo "FAIL a forged entry passed the check" >&2; exit 1; fi
    touch $out
  ''
