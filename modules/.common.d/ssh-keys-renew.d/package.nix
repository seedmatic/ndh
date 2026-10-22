# ssh-keys-renew (see ssh-keys-renew.sh), built for the operator seat. One definition: the seat's module puts it in
# ndh-ops's tools, and the flake's app is that very package.
#   netplan: the catalog's, whose machines --public records (each operator seat and its guest), whose guests get an
#            sshfs key, and whose foreign vz-hosts a vz-recover key.
{
  pkgs,
  ndh,
  netplan,
}:
let
  inherit (pkgs) lib;
  hosts = lib.attrNames netplan.baremetal;
  guests = map (h: netplan.baremetal.${h}.nixosHostname) hosts;
in
ndh.store.installBinScript "ssh-keys-renew" (
  pkgs.replaceVars ./ssh-keys-renew.sh {
    inherit (ndh.context) nixBashTrampoline;
    loggerTag = "ndh.ssh-keys-renew";
    keysJson = "${import ../keys-yaml.d/json-tool.nix { inherit pkgs; }}/bin/ndh-keys-json";
    # What --public records, as ndh-keyring names it: a host key for each of the four machines
    # (each operator seat and its guest), an sshfs key for each NixOS guest, a vz-recover key for
    # each foreign vz-host.
    machines = lib.concatStringsSep " " (hosts ++ guests);
    guests = lib.concatStringsSep " " guests;
    vzHosts = lib.concatStringsSep " " (
      lib.filter (h: netplan.baremetal.${h}.vzHostKind == "foreign") hosts
    );
    toolPath = lib.makeBinPath (
      with pkgs;
      [
        coreutils
        diffutils
        gawk
        git
        gnugrep
        gnused
        openssh
        sops
        step-cli
        yq-go
      ]
    );
  }
)
