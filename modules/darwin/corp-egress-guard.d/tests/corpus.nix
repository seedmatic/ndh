# The v4 anchor, rendered from the catalog, against 🛡️'s corpus: exactly one allow (tcp/22 to the LAN address, as the
# operator), then a block of every protocol to each of the two addresses, which are the catalog's. Each mutant breaks
# one property, and the check must refuse each one: a check that passes them is not checking.
{
  pkgs,
  netplan,
}:
let
  inherit (pkgs) lib;
  lanAddress = netplan.lan.hosts.nikopol-vzhost.ip;
  linkAddress = netplan.baremetal.nikopol.vzHostAddress;
  user = "operator";
  render = import ../anchor.nix { inherit lanAddress linkAddress user; };
  lines = r: lib.splitString "\n" r.text;
  # The corpus's properties, as one predicate: an empty list is a pass, each element names a broken one.
  broken =
    r:
    let
      l = lines r;
      blocks = lib.filter (lib.hasPrefix "block out quick log inet to ") l;
      passes = lib.filter (lib.hasPrefix "pass ") l;
    in
    lib.optional (
      passes != [ "pass out quick inet proto tcp to ${lanAddress} port 22 user ${user} keep state" ]
    ) "the allow-list is not exactly tcp/22 to the LAN address as the operator"
    ++ lib.optional (r.allows != passes) "an allow is not declared in `allows`"
    ++ lib.optional (
      !(lib.elem "block out quick log inet to ${lanAddress}" blocks)
    ) "the LAN address is not blocked"
    ++ lib.optional (
      !(lib.elem "block out quick log inet to ${linkAddress}" blocks)
    ) "the link address is not blocked"
    ++ lib.optional (lib.any (
      b: lib.hasInfix " proto " b || lib.hasInfix " port " b
    ) blocks) "a block is narrowed to a protocol or a port"
    ++ lib.optional (
      !(lib.hasPrefix "pass " (lib.head l))
    ) "the allow is not first (quick: the first match wins)";
  mutate = f: render // { text = lib.concatStringsSep "\n" (f (lines render)); };
  mutants = {
    "the LAN block removed" = mutate (lib.filter (x: x != "block out quick log inet to ${lanAddress}"));
    "the link block removed" = mutate (
      lib.filter (x: x != "block out quick log inet to ${linkAddress}")
    );
    "the allow widened to any port" = mutate (
      map (
        x:
        if lib.hasPrefix "pass " x then
          "pass out quick inet proto tcp to ${lanAddress} user ${user} keep state"
        else
          x
      )
    );
    "the allow widened to any user" = mutate (
      map (
        x:
        if lib.hasPrefix "pass " x then
          "pass out quick inet proto tcp to ${lanAddress} port 22 keep state"
        else
          x
      )
    );
    "a second allow added" = mutate (
      l: l ++ [ "pass out quick inet proto tcp to ${lanAddress} port 5900 keep state" ]
    );
    "a block moved before the allow" = mutate (l: lib.drop 1 l ++ [ (lib.head l) ]);
    "a block narrowed to tcp" = mutate (
      map (
        x:
        if x == "block out quick log inet to ${linkAddress}" then
          "block out quick log inet proto tcp to ${linkAddress}"
        else
          x
      )
    );
  };
  failures =
    lib.optional (
      broken render != [ ]
    ) "the rendered anchor: ${lib.concatStringsSep "; " (broken render)}"
    ++ lib.concatLists (
      lib.mapAttrsToList (n: m: lib.optional (broken m == [ ]) "mutant passed: ${n}") mutants
    );
in
assert lib.assertMsg (failures == [ ]) (lib.concatStringsSep "\n" failures);
pkgs.runCommand "corp-egress-corpus" { } "touch $out"
