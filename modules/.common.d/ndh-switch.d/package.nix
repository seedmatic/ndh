# ndh-switch, the sessions' one switch verb (see ndh-switch.sh). Imported by the darwin module, which puts it on
# the operator seat's PATH, and by the flake's app and checks: one definition.
#
# Its machine list is GENERATED from the catalog (catalog/machines.nix), and each machine is reached by the
# operator's own alias for it (modules/.common.d/operator-aliases.nix): `<kind>.<metalspace>`, with the HostName
# that alias carries; the seat is "" (local). The YAML is written at build time, never read by nix. It is exposed as
# `machines`, so fleet-switch reads the very same list.
{
  pkgs,
  seat,
  catalog,
}:
let
  inherit (pkgs) lib;
  aliases = import ../operator-aliases.nix { inherit lib catalog; };
  entry =
    m:
    let
      isSeat = m.seat or false;
      alias =
        lib.findFirst (a: a.service == m.kind)
          (throw "ndh-switch: no operator alias for kind ${m.kind} (machine ${m.name})")
          (aliases.operatorAliasesOf m.metalspace);
    in
    {
      inherit (m) name kind;
      ssh = if isSeat then "" else "${alias.service}.${m.metalspace}";
      ssh_opts =
        if isSeat || alias.hostName == null then
          [ ]
        else
          [
            "-o"
            "HostName=${alias.hostName}"
          ];
    };
  machines = (pkgs.formats.yaml { }).generate "machines.yaml" (map entry catalog.machines);
in
pkgs.writeShellApplication {
  name = "ndh-switch";
  runtimeInputs = with pkgs; [
    coreutils
    git
    nixos-rebuild-ng
    openssh
    yq-go
  ];
  text = ''
    machines=${machines}
    seat=${lib.escapeShellArg seat}
    remote=https://github.com/seedmatic/ndh
    probe_every=20
    probe_until=180
  ''
  + builtins.readFile ./ndh-switch.sh;
}
// {
  inherit machines;
}
