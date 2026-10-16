# The TLS key of the cache container's leaf, generated once on its persistent disk, and a CSR for
# it. The operator seat fetches the CSR, checks its SAN against the name fixed at eval, signs it
# under mammoth-skate tls and installs the certificate beside the key (the S6 model).
dir="${1:?usage: attic-tls-key <tls dir> <fqdn> <server group>}"
fqdn="${2:?usage: attic-tls-key <tls dir> <fqdn> <server group>}"
group="${3:?usage: attic-tls-key <tls dir> <fqdn> <server group>}"
key="$dir/key.pem"
csr="$dir/request.csr"

umask 077
if [ ! -s "$key" ]; then
  tmp="$(mktemp "$key.XXXXXX")"
  trap 'rm -f "$tmp"' EXIT
  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$tmp"
  mv "$tmp" "$key"
  trap - EXIT
  echo "attic-tls-key: generated $key (ECDSA P-256)"
fi
# nginx runs as its own user: the key is readable by its group, and by nothing else.
chgrp "$group" "$key"
chmod 0640 "$key"

# Rewritten at every start, so a changed fqdn reaches the CSR without touching the key.
umask 022
openssl req -new -key "$key" -subj "/CN=$fqdn" -addext "subjectAltName=DNS:$fqdn" -out "$csr.tmp"
mv "$csr.tmp" "$csr"

if [ -s "$dir/cert.pem" ]; then
  served="$(openssl x509 -in "$dir/cert.pem" -noout -pubkey)"
  held="$(openssl pkey -in "$key" -pubout)"
  if [ "$served" != "$held" ]; then
    echo "attic-tls-key: $dir/cert.pem does not certify $key — re-sign $csr" >&2
    exit 1
  fi
else
  echo "attic-tls-key: no certificate yet — sign $csr and install it as $dir/cert.pem"
fi
