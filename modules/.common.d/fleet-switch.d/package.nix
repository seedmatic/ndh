# fleet-switch: the fleet's ordered loop over ndh-switch (see fleet-switch.sh). Built with the seat's own ndh-switch,
# so the per-machine switch has one implementation, and with ndh-switch's machines.json, so there is one list.
{ pkgs, ndhSwitch }:
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
    machines=${../ndh-switch.d/machines.json}
    signers=${./signers.yaml}
    remote=https://github.com/seedmatic/ndh
    flake_base=github:seedmatic/ndh
  ''
  + builtins.readFile ./fleet-switch.sh;
}
