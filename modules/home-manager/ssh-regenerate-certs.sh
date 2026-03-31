#!/usr/bin/env -S bash -euxo pipefail
# @codebase
# Regenerate SSH certificates by signing keys with their embedded authority CA keys.
# Takes a profile YAML (already extracted from keys.yaml) and generates certificates
# for all keys that have associated authorities.
#
# Usage: ssh-regenerate-certs.sh <profile-yaml> <output-directory>
#
# Certificates are generated at activation time ensuring:
# - Fresh serial numbers for each activation
# - CA signatures remain current
# - Certificates are treated as ephemeral, not committed to git

shopt -s nullglob

yamlFile="$1"
outputDir="$2"

[[ -f "$yamlFile" ]] || {
  echo "Profile YAML file not found: $yamlFile" >&2
  exit 0
}

mkdir -p "$outputDir"

: "Get list of keys in the profile"
keys=()
readarray -t keys < <(@yq@ eval 'keys[]' "$yamlFile")

for keyName in "${keys[@]}"; do
  [[ -z "$keyName" ]] && continue

  : Extract key fields
  keyPublic=$(@yq@ eval ".\"$keyName\".public" "$yamlFile")
  keyType=$(@yq@ eval ".\"$keyName\".type // \"ssh-ed25519\"" "$yamlFile")
  keyComment=$(@yq@ eval ".\"$keyName\".comment // \"\"" "$yamlFile")

  [[ -z "$keyPublic" || "$keyPublic" == "null" ]] && continue

  : "Get list of authorities for this key"
  authorities=()
  readarray -t authorities < <(@yq@ eval ".\"$keyName\".authorities | keys[]" "$yamlFile" 2>/dev/null || true)

  for authorityName in "${authorities[@]}"; do
    [[ -z "$authorityName" ]] && continue

    : "Extract authority CA private key"
    authorityPrivate=$(@yq@ eval ".\"$keyName\".authorities.\"$authorityName\".private" "$yamlFile")

    [[ -z "$authorityPrivate" || "$authorityPrivate" == "null" ]] && continue

    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' RETURN

    keyPubFile="$tmpdir/${keyName}.pub"
    caPrivFile="$tmpdir/${authorityName}-ca"

    : "Write key and CA material to temporary files"
    echo "${keyType} ${keyPublic} ${keyComment}" >"$keyPubFile"
    echo "$authorityPrivate" >"$caPrivFile"
    chmod 400 "$caPrivFile"

    : "Sign key with authority to generate user certificate"
    if ssh-keygen -q -s "$caPrivFile" -I "${keyName}" -n "${keyName}" "$keyPubFile" 2>/dev/null; then
      certFile="$outputDir/${keyName}-${authorityName}-user-cert.pub"
      mv "$keyPubFile"-cert.pub "$certFile" || true
    fi
  done
done

: "Symlink stable <key>-cert.pub to the first matching certificate"
for priv in "$outputDir/"*; do
  [[ -f "$priv" ]] || continue
  case "$priv" in
    *.pub | *-cert.pub) continue ;;
  esac
  
  base="${priv##*/}"
  certs=("$outputDir/${base}"-*-cert.pub)
  
  key_fp="$(ssh-keygen -lf "$priv" 2>/dev/null | awk '{print $2}' || true)"
  [[ -z "$key_fp" ]] && continue
  
  matched_cert=""
  for cert in "${certs[@]}"; do
    [[ -f "$cert" ]] || continue
    cert_fp="$(ssh-keygen -Lf "$cert" 2>/dev/null | awk '/Public key:/ {print $4; exit}' || true)"
    if [[ -n "$cert_fp" && "$cert_fp" == "$key_fp" ]]; then
      matched_cert="$cert"
      break
    fi
  done
  
  if [[ -n "$matched_cert" ]]; then
    cert_basename="${matched_cert##*/}"
    ln -sf "$cert_basename" "$outputDir/${base}-cert.pub"
  else
    rm -f "$outputDir/${base}-cert.pub"
  fi
done

