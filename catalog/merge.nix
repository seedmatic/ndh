# Shared catalog merge law — the ONE place the union/throw group-by-key logic lives, used by both
# `netplan.segments` (key = cidr, list attr = hosts) and `datasets` (key = path). Not duplicated.
#
# `mergeByKey { key, listAttrs ? [] }` groups records by `records.<key>` (preserving first-seen
# order), then per group: unions the SCALAR attrs where a key is defined by only one contributor and
# throws LOUD on a genuine clash (checkMerge — no silent drop), and CONCATenates any `listAttrs`
# (present-only, so an attribution-only span stays `{cidr,name,asn}` with no empty `hosts` key).
# Catalog is lib-free → builtins only.
{
  mergeByKey =
    { key, listAttrs ? [ ] }:
    records:
    let
      keysInOrder = builtins.foldl' (
        acc: r: if builtins.elem r.${key} acc then acc else acc ++ [ r.${key} ]
      ) [ ] records;
      mergeGroup =
        k:
        let
          group = builtins.filter (r: r.${key} == k) records;
          checkMerge =
            a: b:
            let
              clashes = builtins.filter (c: (a ? ${c}) && a.${c} != b.${c}) (builtins.attrNames b);
            in
            if clashes != [ ] then
              throw "catalog merge (${key}=${builtins.toString k}): contributors disagree on ${builtins.concatStringsSep ", " clashes}"
            else
              a // b;
          scalars = builtins.foldl' checkMerge { } (map (r: builtins.removeAttrs r listAttrs) group);
          # Only emit a list attr some contributor actually carries (preserve the sparse shape).
          presentListAttrs = builtins.filter (a: builtins.any (r: r ? ${a}) group) listAttrs;
          lists = builtins.listToAttrs (
            map (a: {
              name = a;
              value = builtins.concatMap (r: r.${a} or [ ]) group;
            }) presentListAttrs
          );
        in
        scalars // lists;
    in
    map mergeGroup keysInOrder;
}
