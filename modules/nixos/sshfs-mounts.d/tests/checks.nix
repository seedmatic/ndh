# The sshfs mounts of the operator seats' git stores (roles × keys S3b), read from the evaluated configurations.
# A guest mounts read-only with its own host key, verifying its seat by the fleet's authority; its seat authorizes
# that host key for read-only sftp only.
{
  pkgs,
  lib,
  nixosConfigurations,
  darwinConfigurations,
  # guest -> its operator seat
  seatOf,
  # machine -> every name its host certificate is signed for
  hostNames,
}:
let
  expect =
    what: actual: wanted:
    lib.assertMsg (
      actual == wanted
    ) "${what}: ${builtins.toJSON actual}, expected ${builtins.toJSON wanted}";
  sftpReadOnly = ''restrict,command="internal-sftp -R"'';

  guest =
    name:
    let
      c = nixosConfigurations.${name}.config;
      cfg = c.services.sshfsMounts;
      seat = seatOf.${name};
      optionsOf = c: map (m: c.fileSystems.${m.localPath}.options) c.services.sshfsMounts.mounts;
      wanted = [
        "x-systemd.automount"
        "x-systemd.idle-timeout=600"
        "x-systemd.mount-timeout=30s"
        "_netdev"
        "allow_other"
        "default_permissions"
        "reconnect"
        "ServerAliveInterval=15"
        "ServerAliveCountMax=3"
        "ConnectTimeout=10"
        "ro"
        "StrictHostKeyChecking=yes"
        "compression=no"
        "cache=yes"
        "kernel_cache"
        "idmap=user"
        "uid=${toString cfg.uid}"
        "gid=${toString cfg.gid}"
        "IdentityFile=${c.ndh.hostKey.file}"
      ];
    in
    assert lib.assertMsg (cfg.enable && cfg.mounts != [ ]) "${name}: mounts nothing over sshfs";
    assert expect "${name} serves its own host key" c.ndh.hostKey.own true;
    assert expect "${name} mount options" (lib.unique (optionsOf c)) [ wanted ];
    # StrictHostKeyChecking=yes holds only where the authority vouches for the name: the seat's own names.
    assert lib.assertMsg (lib.elem cfg.remoteHost hostNames.${seat})
      "${name}: remoteHost ${cfg.remoteHost} is not one of ${seat}'s certified names (${toString hostNames.${seat}})";
    pkgs.runCommand "sshfs-mount-${name}" { } "touch $out";

  seatCheck =
    name: seat:
    let
      user = darwinConfigurations.${seat}.config.profile.user.name;
      line = "ssh-ed25519 AAAAtest ${name}";
      authorizedOf = c: c.environment.etc."ssh/nix_authorized_keys.d/${user}".text or "";
      sshfsLines = c: lib.filter (lib.hasPrefix sftpReadOnly) (lib.splitString "\n" (authorizedOf c));
      committed = darwinConfigurations.${seat}.config;
      tested =
        (darwinConfigurations.${seat}.extendModules {
          modules = [ { ndh.sshfs.guestKeyLines = lib.mkForce [ line ]; } ];
        }).config;
    in
    assert expect "${seat}: its sshfs key options" committed.ndh.sshfs.authorizedOptions sftpReadOnly;
    assert expect "${seat}: the sshfs key it authorizes, with a test public" (sshfsLines tested) [
      "${sftpReadOnly} ${line}"
    ];
    # As committed: exactly the guest's own host key, read-only.
    assert expect "${seat}: the guest key lines" committed.ndh.sshfs.guestKeyLines (
      committed.ndh.keysYaml.authorizedLinesFor [ name ]
    );
    assert lib.assertMsg (
      committed.ndh.sshfs.guestKeyLines != [ ]
    ) "${seat}: authorizes no host key of ${name}";
    assert expect "${seat}: the sshfs keys it authorizes, as committed" (sshfsLines committed) (
      map (l: "${sftpReadOnly} ${l}") committed.ndh.sshfs.guestKeyLines
    );
    pkgs.runCommand "sshfs-authorized-${seat}" { } "touch $out";
in
lib.listToAttrs (
  map (name: lib.nameValuePair "sshfs-mount-${name}" (guest name)) (lib.attrNames seatOf)
)
// lib.listToAttrs (
  lib.mapAttrsToList (
    name: seat: lib.nameValuePair "sshfs-authorized-${seat}" (seatCheck name seat)
  ) seatOf
)
