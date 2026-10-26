# fleet-switch: the fleet's ordered loop over ndh-switch (see fleet-switch.sh). Built with the seat's own ndh-switch,
# so the per-machine switch has one implementation, and with the machine list that ndh-switch generates from the
# catalog, so there is one list.
{
  pkgs,
  ndhSwitch,
  # ndh-ops's delegation file, which a real run must find armed for fleet-switch (ndh-ops.d/paths.nix).
  delegation ? (import ../ndh-ops.d/paths.nix).delegation,
}:
pkgs.writeShellApplication {
  name = "fleet-switch";
  runtimeInputs = with pkgs; [
    coreutils
    git
    gnused
    yq-go
  ];
  text = ''
    ndh_switch=${ndhSwitch}/bin/ndh-switch
    machines=${ndhSwitch.machines}
    signers=${./signers.yaml}
    remote=https://github.com/seedmatic/ndh
    flake_base=github:seedmatic/ndh
    delegation=${pkgs.lib.escapeShellArg delegation}
  ''
  + builtins.readFile ./fleet-switch.sh;
}
