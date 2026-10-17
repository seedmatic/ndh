# ndh-nix-signing-key: place this machine's nix signing key, derived from its own host key (roles × keys B2).
# The header sets derive, hostKeyFile, name, label, recorded and dir. The derived public must be the one
# keys.yaml records: a host key replaced without a new record signs nothing. nix re-reads the file at each
# signing, so it is replaced by a rename, never rewritten in place, and the previous one stays on a refusal.

die() {
  printf '[ndh-nix-signing-key] ERROR: %s\n' "$*" >&2
  exit 1
}

[[ -s $hostKeyFile ]] || die "no host key at ${hostKeyFile}: nothing to derive the signing key from"
umask 077
install -d -m 0700 "$dir"
public="$("$derive" --name "$name" --label "$label" --public <"$hostKeyFile")" ||
  die "deriving ${name} from ${hostKeyFile} failed"
[[ $public == "$recorded" ]] ||
  die "the key derived from ${hostKeyFile} is not the ${name} keys.yaml records: record it again (ndh-keyring nix-signing-public), nothing replaced"

tmp="$(mktemp "${dir}/.${name}.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
"$derive" --name "$name" --label "$label" --secret <"$hostKeyFile" >"$tmp" || die "deriving ${name}'s secret failed"
chmod 0400 "$tmp"
mv -f "$tmp" "${dir}/${name}.sec"
trap - EXIT
printf '[ndh-nix-signing-key] %s placed at %s/%s.sec\n' "$name" "$dir" "$name" >&2
