# private-caches.nix as a flake check: an accepted entry is trusted by exactly the kinds it lists, and
# every break of the schema is refused at evaluation (a throw, which tryEval catches).
{ pkgs }:
let
  inherit (pkgs) lib;
  privateCaches = import ../../private-caches.nix {
    atticFqdns = {
      alpha = "attic.alpha";
      beta = "attic.beta";
    };
    machines = [
      {
        name = "alpha";
        kind = "darwin";
        metalspace = "alpha";
      }
      {
        name = "alpha-nixos";
        kind = "nixos";
        metalspace = "alpha";
      }
    ];
  };
  key = ms: "seedmatic-${ms}-attic-1:${lib.strings.replicate 43 "A"}=";
  entry = {
    publicKey = key "alpha";
    consumers = [ "attic.alpha" ];
    acceptedBy = [ "nixos" ];
    accepted = {
      date = "2026-10-17";
      commit = "8c27a29e";
    };
    lifecycle = "stable";
  };
  accepted = entries: (privateCaches entries).entries;
  refused = entries: !(builtins.tryEval (builtins.deepSeq (accepted entries) true)).success;
  refusedAlpha = change: refused { alpha = entry // change; };
in
assert lib.assertMsg (
  (privateCaches { alpha = entry; }).readKeysFor "nixos" == [ (key "alpha") ]
) "private-caches: a kind listed in acceptedBy must trust the key";
assert lib.assertMsg (
  (privateCaches { alpha = entry; }).readKeysFor "darwin" == [ ]
) "private-caches: a kind not listed in acceptedBy must not trust the key";
assert lib.assertMsg (
  (privateCaches { }).readKeysFor "darwin" == [ ]
) "private-caches: no entry, no key";
assert lib.assertMsg (
  !(builtins.tryEval ((privateCaches { alpha = entry; }).readKeysFor "cluster")).success
) "private-caches: a kind that is no machine's must be refused";
assert lib.assertMsg (refused {
  gamma = entry // {
    publicKey = key "gamma";
    consumers = [ "attic.gamma" ];
  };
}) "private-caches: an unknown metalspace must be refused";
assert lib.assertMsg (refusedAlpha {
  replacedBy = "seedmatic-alpha-attic-2";
}) "private-caches: a field outside the schema must be refused";
assert lib.assertMsg (refused {
  alpha = builtins.removeAttrs entry [ "accepted" ];
}) "private-caches: an entry without the operator's acceptance must be refused";
assert lib.assertMsg (refusedAlpha {
  publicKey = key "beta";
}) "private-caches: another metalspace's key name must be refused";
assert lib.assertMsg (refusedAlpha {
  publicKey = "seedmatic-alpha-attic-1:short";
}) "private-caches: a malformed public key must be refused";
assert lib.assertMsg (refusedAlpha {
  consumers = [ "attic.beta" ];
}) "private-caches: a holder other than the metalspace's own container must be refused";
assert lib.assertMsg (refusedAlpha {
  consumers = [
    "attic.alpha"
    "alpha"
  ];
}) "private-caches: a private held outside its container must be refused";
assert lib.assertMsg (refusedAlpha {
  acceptedBy = [ ];
}) "private-caches: an empty acceptedBy must be refused";
assert lib.assertMsg (refusedAlpha {
  acceptedBy = [
    "nixos"
    "cluster"
  ];
}) "private-caches: a cluster in acceptedBy must be refused";
assert lib.assertMsg (refusedAlpha {
  accepted = {
    date = "17/10/2026";
    commit = "8c27a29e";
  };
}) "private-caches: a malformed acceptance date must be refused";
assert lib.assertMsg (refusedAlpha {
  accepted = {
    date = "2026-10-17";
    commit = "develop";
  };
}) "private-caches: an acceptance commit that is no revision must be refused";
assert lib.assertMsg (refusedAlpha {
  accepted = {
    date = "2026-10-17";
    commit = "8c27a29e";
    by = "x";
  };
}) "private-caches: a field outside accepted's schema must be refused";
assert lib.assertMsg (refusedAlpha {
  lifecycle = "retired";
}) "private-caches: a lifecycle outside the enum must be refused";
pkgs.runCommand "private-caches-schema" { } "touch $out"
