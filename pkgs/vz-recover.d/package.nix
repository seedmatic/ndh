# ndh-vz-recover, the forced command of the vz-recover key on a foreign vz-host: its metalspace's Tart VMs,
# each with the kind of system it runs. Installed by the operator into the vz-host account's nix profile.
{
  pkgs,
  lib,
  vms,
}:
pkgs.writeShellApplication {
  name = "ndh-vz-recover";
  runtimeInputs = [ pkgs.coreutils ];
  text = ''
    vms=(${lib.concatMapStringsSep " " (vm: lib.escapeShellArg vm.name) vms})
    kinds=(${lib.concatMapStringsSep " " (vm: lib.escapeShellArg vm.kind) vms})
    tart=${pkgs.tart}/bin/tart
    timeout=${pkgs.coreutils}/bin/timeout
    open=/usr/bin/open
  ''
  + builtins.readFile ./ndh-vz-recover.sh;
  # The authorized_keys options of the vz-recover key: no pty, no forwarding, no agent, no rc, and this
  # program in place of whatever the client asks. The real-sshd check serves this very string.
  passthru.authorizedOptions = command: ''restrict,command="${command}"'';
}
