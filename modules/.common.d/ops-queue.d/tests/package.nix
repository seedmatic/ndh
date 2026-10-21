# ops-queue's checks as one flake check:
#   1. the derivation: each state of a machine slot gives the expected step, in fleet-switch's order, and the
#      repo's own keys.json gives an empty head today (no slot born on a host yet);
#   2. the BUILT `ops` on queues derived from fixtures (bats), including mutants of the frozen queue it must refuse.
{
  pkgs,
  catalog,
  ndh,
}:
let
  inherit (pkgs) lib;
  machines = {
    machines = [
      {
        name = "g1";
        kind = "nixos";
      }
      {
        name = "seat";
        kind = "darwin";
        seat = true;
      }
      {
        name = "g2";
        kind = "nixos";
      }
      {
        name = "mac";
        kind = "darwin";
      }
    ];
  };
  slot = state: origin: { inherit state origin; };
  keysOf = slots: lib.mapAttrs (_: s: { inherit (s) slots; }) slots;
  derive =
    keys:
    import ../queue.nix {
      inherit lib keys;
      catalog = machines;
    };
  build =
    name: keys:
    import ../package.nix {
      inherit pkgs ndh keys;
      catalog = machines;
    };
  serving = slot "serving" "keyring";

  fixtures = {
    empty = { };
    keyring-only = keysOf {
      host-g1.slots."26-10-17" = serving;
      host-mac.slots."26-10-18" = slot "recorded" "keyring";
    };
    generate = keysOf {
      host-seat.slots = {
        "26-10-17" = serving;
        "26-11-01" = slot "pending" "host";
      };
      host-g1.slots = {
        "26-10-17" = serving;
        "26-11-01" = slot "pending" "host";
      };
      host-mac.slots = {
        "26-10-17" = serving;
        "26-11-01" = slot "pending" "host";
      };
    };
    mixed = keysOf {
      host-g1.slots = {
        "26-10-17" = serving;
        "26-11-01" = slot "generated" "host";
      };
      host-g2.slots = {
        "26-10-17" = serving;
        "26-11-01" = slot "pending" "host";
      };
    };
    window = keysOf {
      host-g1.slots = {
        "26-10-17" = serving;
        "26-11-01" = slot "generated" "host";
      };
    };
    serve = keysOf {
      host-mac.slots = {
        "26-10-17" = serving;
        "26-11-01" = slot "recorded" "host";
      };
      sshfs-g2.slots = {
        "26-10-17" = serving;
        "26-11-01" = slot "recorded" "host";
      };
    };
  };
  q = lib.mapAttrs (_: derive) fixtures;
  steps = e: map (x: "${x.step}:${x.machine}") e;

  # (1) the derivation, asserted at evaluation: a wrong head fails the build of this check.
  expect =
    name: got: want:
    lib.assertMsg (
      got == want
    ) "ops-queue ${name}: got ${builtins.toJSON got}, want ${builtins.toJSON want}";
  derivationOk =
    assert expect "empty: no head" q.empty.head [ ];
    assert expect "keyring slots are never offered" q.keyring-only.head [ ];
    assert expect "keyring slots wait for a declaration" (map (w: w.key) q.keyring-only.waiting) [
      "host-mac"
    ];
    assert expect "generate, in fleet-switch's order (guests, darwin, seat last)"
      (steps q.generate.head)
      [
        "generate:g1"
        "generate:mac"
        "generate:seat"
      ];
    assert expect "generate shows the reachability as unchecked, never met" (lib.all (
      e: e.unchecked == [ "${e.machine} joignable" ]
    ) q.generate.head) true;
    assert expect "the earliest step is the head; the later one is blocked" (steps q.mixed.head) [
      "generate:g2"
    ];
    assert expect "the later step names why" (map (e: lib.last e.checked) q.mixed.blocked) [
      "le pas précédent n'est pas fini sur toute la flotte"
    ];
    assert expect "window: refused until K4, by name" (map (e: e.checked) q.window.head) [
      [ "le pas « ouvrir la fenêtre » arrive avec K4 (keys-reconcile)" ]
    ];
    assert expect "serve: host keys and sshfs keys alike, in order" (steps q.serve.head) [
      "serve:g2"
      "serve:mac"
    ];
    true;

  repoQueue = import ../queue.nix {
    inherit lib catalog;
    keys = (builtins.fromJSON (builtins.readFile ../../../home-manager/ssh.d/keys.json)).keys;
  };
  ops = lib.mapAttrs build fixtures;
in
assert derivationOk;
assert lib.assertMsg (
  repoQueue.head == [ ]
) "ops-queue: the repo's keys.json offers a step today: ${builtins.toJSON repoQueue.head}";
pkgs.runCommand "ops-queue-checks"
  {
    nativeBuildInputs = with pkgs; [
      bats
      bash
      coreutils
      gnugrep
      yq-go
    ];
    OPS_EMPTY = "${ops.empty}/bin/ops";
    OPS_KEYRING = "${ops.keyring-only}/bin/ops";
    OPS_GENERATE = "${ops.generate}/bin/ops";
    OPS_MIXED = "${ops.mixed}/bin/ops";
    OPS_WINDOW = "${ops.window}/bin/ops";
    OPS_SERVE = "${ops.serve}/bin/ops";
    # The script as the package substitutes it, with its queue left to set: the mutants point it at other files.
    OPS_SH = pkgs.replaceVars ../ops.sh {
      inherit (ndh.context) nixBashTrampoline;
      loggerTag = "ndh.ops.test";
      toolPath = pkgs.lib.makeBinPath [
        pkgs.coreutils
        pkgs.yq-go
      ];
      queue = "/the-mutant-queue";
    };
  }
  ''
    cp -r ${./.} tests && chmod -R u+w tests
    cd tests && HOME=$TMPDIR bats ops.bats
    touch $out
  ''
