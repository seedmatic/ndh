# The live machines of the fleet: the ones ndh-switch may switch and fleet-switch orders. One entry per machine.
#   name:       its flake configuration (nixosConfigurations.<name> or darwinConfigurations.<name>)
#   kind:       "nixos", a NixOS guest, evaluated on the operator seat and pushed with --target-host;
#               "darwin", a darwin host, switched in place with /usr/bin/sudo darwin-rebuild
#   metalspace: the metalspace it belongs to; its ssh name is `<kind>.<metalspace>`, the operator's own alias
#               (modules/.common.d/operator-aliases.nix), so a switch dials what the operator types
#   seat:       true for the operator seat, which is switched locally and LAST by fleet-switch
#   attic:      what this machine does with the private caches, both off by default: `read` (substitute from them),
#               `push` (its watch-store into its own metalspace's); turned on one machine at a time
# The build, bringup and Tart variants of these configurations are not machines: they are absent on purpose.
[
  {
    name = "bioskop-nixos";
    kind = "nixos";
    metalspace = "bioskop";
    attic.read = true;
  }
  {
    name = "bioskop";
    kind = "darwin";
    metalspace = "bioskop";
    seat = true;
  }
  {
    name = "nikopol-nixos";
    kind = "nixos";
    metalspace = "nikopol";
  }
  {
    name = "nikopol";
    kind = "darwin";
    metalspace = "nikopol";
  }
]
