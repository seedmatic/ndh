# Every TLS leaf in catalog/attic-leaves/ is one keys-reconcile signed, never a hand-placed certificate (R1, class
# attic-tls-csr): <ms>.crt chains to the TLS authority's recorded slot, names exactly its cache's fabric name, is no CA
# and carries the key of <ms>.csr, whose statement (<ms>.csr.statement, .sig) names that CSR's sha256, this cache and
# its guest, and verifies against the guest's RECORDED serving host key, namespace seedmatic-attic. A leaf without
# that chain, or a file left without its leaf, is refused; a forged leaf must be refused in the same build.
{
  pkgs,
  leaves,
  # metalspace → { machine; public; fqdn; }: its guest, that guest's serving host key as keys.json records it, and the
  # cache's fabric name
  signers,
  # the TLS authority's recorded certificate (its signing slot's cleartext ca_crt)
  caCrt,
}:
let
  inherit (pkgs) lib;
  table = lib.concatMapStrings (
    ms: "${ms}\t${signers.${ms}.machine}\t${signers.${ms}.public}\t${signers.${ms}.fqdn}\n"
  ) (lib.attrNames signers);
in
pkgs.runCommand "attic-leaves-recorded"
  {
    nativeBuildInputs = [
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.gnused
      pkgs.openssh
      pkgs.openssl
    ];
    inherit table caCrt;
    passAsFile = [
      "table"
      "caCrt"
    ];
  }
  ''
    pub() { openssl "$1" -in "$2" -noout -pubkey | openssl pkey -pubin -outform DER | sha256sum | cut -d' ' -f1; }
    sans() { openssl "$1" -in "$2" -noout -text | grep -A1 'Subject Alternative Name' | tail -1 | tr ',' '\n' | sed -e 's/^ *//' -e 's/^DNS://' | sed '/^$/d' | sort -u; }
    # check <leaves dir>: 0 when every leaf there is backed by its verified chain, and no file is left over
    check() {
      local d="$1" fail=0 ms machine public fqdn f
      while IFS=$'\t' read -r ms machine public fqdn; do
        [ -e "$d/$ms.crt" ] || continue
        for f in csr csr.statement csr.statement.sig; do
          [ -f "$d/$ms.$f" ] || { echo "$ms: $f missing beside its leaf: not written by keys-reconcile" >&2; fail=1; continue 2; }
        done
        openssl verify -CAfile "$caCrtPath" -no-CApath -no-CAstore "$d/$ms.crt" >/dev/null 2>&1 ||
          { echo "$ms: the leaf does not chain to the TLS authority's recorded slot" >&2; fail=1; continue; }
        [ "$(sans x509 "$d/$ms.crt")" = "$fqdn" ] || { echo "$ms: the leaf names more or other than $fqdn" >&2; fail=1; continue; }
        ! openssl x509 -in "$d/$ms.crt" -noout -text | grep -q 'CA:TRUE' || { echo "$ms: the leaf is a CA" >&2; fail=1; continue; }
        [ "$(pub x509 "$d/$ms.crt")" = "$(pub req "$d/$ms.csr")" ] || { echo "$ms: the leaf does not carry its CSR's key" >&2; fail=1; continue; }
        [ "$(cat "$d/$ms.csr.statement")" = "$(printf 'seedmatic-attic v1\nclass attic-tls-csr\ncache %s\nmachine %s\nsha256 %s' "$ms" "$machine" "$(sha256sum "$d/$ms.csr" | cut -d' ' -f1)")" ] ||
          { echo "$ms: its CSR's statement does not name this CSR, this cache and $machine" >&2; fail=1; continue; }
        printf 'host-%s %s\n' "$machine" "$public" >allowed
        ssh-keygen -q -Y verify -f allowed -I "host-$machine" -n seedmatic-attic -s "$d/$ms.csr.statement.sig" <"$d/$ms.csr.statement" >/dev/null 2>&1 ||
          { echo "$ms: its CSR's statement is not signed by $machine's recorded host key" >&2; fail=1; }
      done <"$tablePath"
      for f in "$d"/*; do
        [ -e "$f" ] || continue
        case "$(basename "$f")" in .keep) continue ;; esac
        ms="$(basename "$f")"; ms="''${ms%%.*}"
        [ -e "$d/$ms.crt" ] && cut -f1 "$tablePath" | grep -qx "$ms" ||
          { echo "$(basename "$f"): no leaf of a declared cache beside it" >&2; fail=1; }
      done
      return $fail
    }
    check ${leaves} || { echo "FAIL catalog/attic-leaves/ holds a leaf keys-reconcile did not sign" >&2; exit 1; }
    : "a forged leaf: self-signed, the right name, no chain"
    mkdir forged
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout forged/k -subj "/CN=$(sed -n 1p "$tablePath" | cut -f4)" \
      -addext "subjectAltName=DNS:$(sed -n 1p "$tablePath" | cut -f4)" -days 1 -out "forged/$(sed -n 1p "$tablePath" | cut -f1).crt" 2>/dev/null
    rm forged/k
    if check forged 2>/dev/null; then echo "FAIL a forged leaf passed the check" >&2; exit 1; fi
    touch $out
  ''
