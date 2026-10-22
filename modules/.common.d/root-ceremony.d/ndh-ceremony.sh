# ndh-ceremony init — the seedmatic root's first ceremony, run by the operator at the ceremony VM's console
# (roles × keys ⑧, docs/root-ceremony.adoc). The header sets: in (read-only: the seedmatic key's PUBLIC,
# seedmatic.asc), out (the outputs), work (RAM only), passphraseFrom (the console), attest (ndh-root-attest),
# recipient (the seedmatic encryption subkey, the keyring's only recipient) and logger (its secret window).
#
# It generates, in RAM: the root's dedicated gpg key (the passphrase typed twice, diceware, 7 words or more); the
# P-384 root and its self-signed X.509 root; the fabric's SSH HOST and USER authorities; the TLS intermediate,
# signed by the root; the root's statements over the two SSH authorities, each verified at once. What leaves,
# to out: privates ENCRYPTED only (the root to its gpg key, the three authorities to the seedmatic subkey),
# publics, certificates, statements, and the ceremony log. Nothing is written in clear outside work.

readonly years=2
umask 077

die() {
  printf '[ndh-ceremony] ERROR: %s\n' "$*" >&2
  exit 1
}
say() { printf '[ndh-ceremony] %s\n' "$*" >&2; }

(($# == 1)) && [[ $1 == init ]] || die "usage: ndh-ceremony init"
[[ -f $in/seedmatic.asc ]] || die "${in}/seedmatic.asc is missing: the seedmatic subkey's public, gpg --export"
[[ -d $out && -z "$(ls -A "$out")" ]] || die "${out} must be an empty directory"
for f in root.gpg fabric-ssh-host.gpg fabric-ssh-user.gpg mammoth-skate-tls.gpg; do
  [[ ! -e $out/$f ]] || die "${out}/${f} exists: a ceremony never overwrites"
done

mkdir -p "$work"
chmod 0700 "$work"
trap 'rm -rf "$work"' EXIT
export GNUPGHOME="$work/gnupg"
mkdir -m 0700 "$GNUPGHOME"

today="$(date -u +%F)"
notAfter="$(date -u -d "$today + $((years * 365)) days" +%F)"

# The passphrase is read from the console only, never echoed, and kept in this process alone.
# The passphrase reaches gpg only through a here-string (gpgp), which xtrace does not print (measured, bash 5.3);
# the window covers where it is EXPANDED in a traced command: the two reads' comparison and the word count.
# A failure inside it exits with xtrace off.
# shellcheck source=/dev/null
source "$logger"
ndh::secret:begin "the root passphrase is read and checked"
read -r -s -p "root gpg passphrase (diceware, 7 words or more): " pass <"$passphraseFrom"
printf '\n' >&2
read -r -s -p "again: " again <"$passphraseFrom"
printf '\n' >&2
[[ $pass == "$again" ]] || die "the two passphrases differ"
read -r -a words <<<"$pass"
((${#words[@]} >= 7)) || die "the passphrase has ${#words[@]} words: 7 or more"
unset again words
ndh::secret:end

gpgp() { gpg --batch --pinentry-mode loopback --passphrase-fd 3 "$@" 3<<<"$pass"; }

say "the root's gpg key"
gpgp --quick-generate-key "seedmatic-root (offline) <root@seedmatic.invalid>" nistp384 cert,sign never 2>/dev/null
rootGpg="$(gpg --batch --with-colons --list-keys root@seedmatic.invalid | awk -F: '/^fpr:/ { print $10; exit }')"
[[ -n $rootGpg ]] || die "no root gpg key was generated"
gpgp --quick-add-key "$rootGpg" nistp384 encr never 2>/dev/null
gpg --batch --import "$in/seedmatic.asc" 2>/dev/null
gpg --batch --with-colons --list-keys "${recipient}!" >/dev/null 2>&1 ||
  die "${in}/seedmatic.asc does not hold the seedmatic subkey ${recipient}"
rootEncr="$(gpg --batch --with-colons --list-keys "$rootGpg" | awk -F: '$1 == "sub" && $12 ~ /e/ { print $5; exit }')"
[[ -n $rootEncr ]] || die "the root gpg key has no encryption subkey"

say "the P-384 root"
ssh-keygen -q -t ecdsa -b 384 -m PEM -N "" -C "seedmatic-root@${today}" -f "$work/root"
openssl req -x509 -new -key "$work/root" -sha384 -days 3650 -subj "/CN=seedmatic root" \
  -addext "basicConstraints=critical,CA:TRUE,pathlen:1" -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -out "$out/seedmatic-root.crt" 2>/dev/null

say "the fabric's SSH authorities"
for usage in host user; do
  ssh-keygen -q -t ed25519 -N "" -C "fabric-ssh-${usage}@${today}" -f "$work/fabric-ssh-${usage}"
done

say "the TLS intermediate"
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-384 -out "$work/mammoth-skate-tls" 2>/dev/null
openssl req -new -key "$work/mammoth-skate-tls" -subj "/CN=mammoth-skate tls" -out "$work/tls.csr" 2>/dev/null
printf 'basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\n' >"$work/tls.ext"
openssl x509 -req -in "$work/tls.csr" -CA "$out/seedmatic-root.crt" -CAkey "$work/root" -set_serial "0x$(openssl rand -hex 16)" \
  -sha384 -days "$((years * 365))" -extfile "$work/tls.ext" -out "$out/mammoth-skate-tls.crt" 2>/dev/null
openssl verify -CAfile "$out/seedmatic-root.crt" "$out/mammoth-skate-tls.crt" >/dev/null ||
  die "the intermediate does not chain to the root"

say "the root's statements"
rootPub="$(cut -d' ' -f1,2 "$work/root.pub")"
for usage in host user; do
  name="fabric-ssh-${usage}"
  key="$(cut -d' ' -f1,2 "$work/${name}.pub")"
  "$attest" statement --name "$name" --usage "ssh-${usage}" --key "$key" --not-after "$notAfter" >"$out/${name}.statement"
  ssh-keygen -q -Y sign -f "$work/root" -n seedmatic-attest "$out/${name}.statement"
  "$attest" verify --root "$rootPub" --statement "$out/${name}.statement" \
    --signature "$out/${name}.statement.sig" --name "$name" --usage "ssh-${usage}" --key "$key" >/dev/null ||
    die "the statement of ${name} does not verify"
  cp "$work/${name}.pub" "$out/${name}.pub"
done
cp "$work/root.pub" "$out/seedmatic-root.pub"

say "the encrypted privates"
# Each to ONE subkey, checked on the packets: the root to its own gpg key, the authorities to the seedmatic subkey.
encryptTo() { # <subkey id> <clear file> <out file>
  local keyids
  gpg --batch --trust-model always --encrypt -r "${1}!" -o "$3" "$2"
  mapfile -t keyids < <(gpg --batch --list-only --list-packets "$3" 2>/dev/null |
    sed -n 's/^:pubkey enc packet:.* keyid \([0-9A-Fa-f]*\).*/\1/p')
  [[ ${#keyids[@]} -eq 1 && ${keyids[0]^^} == "${1^^}" ]] || die "${3} is not encrypted to ${1} alone"
}
encryptTo "$rootEncr" "$work/root" "$out/root.gpg"
for name in fabric-ssh-host fabric-ssh-user mammoth-skate-tls; do
  encryptTo "$recipient" "$work/${name}" "$out/${name}.gpg"
done
gpg --batch --armor --export "$rootGpg" >"$out/root-gpg.pub.asc"
gpgp --armor --export-secret-keys "$rootGpg" >"$out/root-gpg.sec.asc"
unset pass

fp() { ssh-keygen -lf "$1" | awk '{ print $2 }'; }
{
  printf 'seedmatic root ceremony (init)\n'
  printf 'date %s\n' "$today"
  printf 'root gpg %s\n' "$rootGpg"
  printf 'root ssh %s\n' "$(fp "$out/seedmatic-root.pub")"
  printf 'root x509 %s\n' "$(openssl x509 -in "$out/seedmatic-root.crt" -noout -fingerprint -sha256 | cut -d= -f2)"
  printf 'fabric-ssh-host %s until %s\n' "$(fp "$out/fabric-ssh-host.pub")" "$notAfter"
  printf 'fabric-ssh-user %s until %s\n' "$(fp "$out/fabric-ssh-user.pub")" "$notAfter"
  printf 'mammoth-skate-tls %s until %s\n' \
    "$(openssl x509 -in "$out/mammoth-skate-tls.crt" -noout -fingerprint -sha256 | cut -d= -f2)" \
    "$(date -u -d "$(openssl x509 -in "$out/mammoth-skate-tls.crt" -noout -enddate | cut -d= -f2)" +%F)"
  printf 'vm destroyed: (to fill in after the runner checks it)\n'
} >"$out/ceremony.log"
say "done: the outputs are in ${out}; nothing of the root is left in clear once this exits"
