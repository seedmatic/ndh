# host-names.nix as a flake check: each machine gets its own names, and a name or a machine two
# entries claim is refused at evaluation (a throw, which tryEval catches).
{ pkgs }:
let
  inherit (pkgs) lib;
  hostNames = import ../host-names.nix { inherit lib; };
  guest = host: {
    guestHostName = "${host}-nixos";
    guestName = "nixos";
    hostName = host;
  };
  refused = fleet: !(builtins.tryEval (builtins.deepSeq (hostNames fleet) true)).success;
in
assert lib.assertMsg (
  hostNames {
    domain = "fabric.test";
    hosts = [
      "alpha"
      "beta"
    ];
    guests = [ (guest "alpha") ];
  } == {
    alpha = [
      "alpha"
      "alpha.fabric.test"
      "alpha.lan"
      "alpha.local"
    ];
    alpha-nixos = [
      "alpha-nixos"
      "alpha-nixos.fabric.test"
      "alpha-nixos.lan"
      "alpha-nixos.local"
      "nixos.alpha"
    ];
    beta = [
      "beta"
      "beta.fabric.test"
      "beta.lan"
      "beta.local"
    ];
  }
) "host-names: each machine must get exactly its own forms";
assert lib.assertMsg (refused {
  domain = "fabric.test";
  hosts = [
    "alpha"
    "nixos.alpha"
  ];
  guests = [ (guest "alpha") ];
}) "host-names: a name two machines claim must be refused";
assert lib.assertMsg (refused {
  domain = "fabric.test";
  hosts = [
    "alpha"
    "alpha-nixos"
  ];
  guests = [ (guest "alpha") ];
}) "host-names: a machine declared twice must be refused";
pkgs.runCommand "ssh-keys-certify-host-names" { } "touch $out"
