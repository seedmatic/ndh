# The private caches' trust (docs/private-binary-cache-spec.adoc, the consumers / acceptedBy axis), checked
# at evaluation. An entry is the operator's acceptance of one metalspace's attic public key: it exists only
# once merged, and a machine trusts it only if its kind is listed. Uniform with roles × keys step 5's
# fields, in keys.yaml's sense:
#   consumers  — who holds the private: that metalspace's cache container, alone (attic generated it there)
#   acceptedBy — the machine kinds that may trust the public (catalog/machines.nix). Never a cluster: the
#                clusters read the public level only, and they are no machine kind, so naming one is refused
#   accepted   — { date; }: the day of the operator's acceptance; the act itself is the merge of the entry
#   lifecycle  — step 5's enum; "permanent" alone until an entry needs another (no rotation yet, no replacedBy)
# and one field of cache-trust's own, which keys.yaml does not carry:
#   origin     — { revision; }: the ndh revision the container was delivered from, whose attic-cache-ensure
#                journal printed this key
{
  # metalspace → its cache container's fabric name (catalog netplan.baremetal.<ms>.atticFqdn)
  atticFqdns,
  # catalog/machines.nix
  machines,
}:
entries:
let
  inherit (builtins)
    attrNames
    concatMap
    elem
    filter
    match
    sort
    throw
    ;
  kinds = builtins.attrNames (
    builtins.listToAttrs (
      map (m: {
        name = m.kind;
        value = null;
      }) machines
    )
  );
  lifecycles = [ "permanent" ];
  fields = [
    "accepted"
    "acceptedBy"
    "consumers"
    "lifecycle"
    "origin"
    "publicKey"
  ];
  refuse = ms: why: throw "catalog privateCaches.${ms}: ${why}";
  check =
    ms: entry:
    let
      keyName = match "(seedmatic-${ms}-attic-[0-9]+):[A-Za-z0-9+/]{43}=" (entry.publicKey or "");
      strangers = filter (kind: !elem kind kinds) (entry.acceptedBy or [ ]);
    in
    if !(atticFqdns ? ${ms}) then
      refuse ms "no such metalspace (known: ${toString (attrNames atticFqdns)})"
    else if sort (a: b: a < b) (attrNames entry) != fields then
      refuse ms "the fields are exactly ${toString fields}, got ${toString (attrNames entry)}"
    else if keyName == null then
      refuse ms "publicKey must be seedmatic-${ms}-attic-<n>:<base64 ed25519>, as attic-cache-ensure prints it"
    else if entry.consumers != [ atticFqdns.${ms} ] then
      refuse ms "consumers must be [ ${atticFqdns.${ms}} ]: the private never leaves its container"
    else if entry.acceptedBy == [ ] then
      refuse ms "acceptedBy is empty: a key nobody may trust has no business here"
    else if strangers != [ ] then
      refuse ms "acceptedBy names ${toString strangers}, not a machine kind (${toString kinds}); a cluster reads the public level only"
    else if match "[0-9]{4}-[0-9]{2}-[0-9]{2}" (entry.accepted.date or "") == null then
      refuse ms "accepted.date must be YYYY-MM-DD"
    else if attrNames entry.accepted != [ "date" ] then
      refuse ms "accepted is exactly { date; }"
    else if match "[0-9a-f]{7,40}" (entry.origin.revision or "") == null then
      refuse ms "origin.revision must be the ndh revision the container was delivered from"
    else if attrNames entry.origin != [ "revision" ] then
      refuse ms "origin is exactly { revision; }"
    else if !elem entry.lifecycle lifecycles then
      refuse ms "lifecycle must be one of ${toString lifecycles}"
    else
      entry;
  checked = builtins.mapAttrs check entries;
in
{
  entries = checked;
  # The public keys a machine of this kind trusts: the accepted ones listing it, and no other.
  readKeysFor =
    kind:
    if !elem kind kinds then
      throw "catalog privateCaches: ${kind} is not a machine kind (${toString kinds})"
    else
      concatMap (ms: if elem kind checked.${ms}.acceptedBy then [ checked.${ms}.publicKey ] else [ ]) (
        attrNames checked
      );
}
