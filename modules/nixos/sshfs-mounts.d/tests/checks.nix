# The sshfs mounts of the operator seats' git stores (roles × keys S3b), read from the evaluated configurations.
# A guest mounts with rdp-host as today until ndh.sshfs.ownKey, then read-only with its own key, verifying its
# seat by the fleet's authority; its receive takes the sshfs key; its seat authorizes that key for read-only
# sftp only. ownKey and the seat's line are evaluated with test values: keys.yaml records no sshfs key until
# the operator does.
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
  sshfsKeyFile =
    (import ../../../.common.d/identity-push.d/package.nix { inherit pkgs lib; }).sshfsKeyFile;
  sftpReadOnly = ''restrict,command="internal-sftp -R"'';

  guest =
    name:
    let
      shared = nixosConfigurations.${name}.config;
      owned =
        (nixosConfigurations.${name}.extendModules {
          modules = [ { ndh.sshfs.ownKey = true; } ];
        }).config;
      cfg = shared.services.sshfsMounts;
      seat = seatOf.${name};
      optionsOf = c: map (m: c.fileSystems.${m.localPath}.options) c.services.sshfsMounts.mounts;
      receiveText =
        builtins.unsafeDiscardStringContext
          (lib.findFirst (
            p: lib.getName p == "ndh-identity-receive"
          ) (throw "${name}: no ndh-identity-receive") shared.environment.systemPackages).text;
      today = [
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
        "StrictHostKeyChecking=accept-new"
        "compression=no"
        "cache=yes"
        "kernel_cache"
        "idmap=user"
        "uid=${toString cfg.uid}"
        "gid=${toString cfg.gid}"
        "IdentityFile=${cfg.identityFile}"
      ];
      # Today's, but read-only, strict, and with the guest's own key.
      owning = lib.concatMap (
        o:
        if o == "StrictHostKeyChecking=accept-new" then
          [
            "ro"
            "StrictHostKeyChecking=yes"
          ]
        else if lib.hasPrefix "IdentityFile=" o then
          [ "IdentityFile=${sshfsKeyFile}" ]
        else
          [ o ]
      ) today;
    in
    assert lib.assertMsg (cfg.enable && cfg.mounts != [ ]) "${name}: mounts nothing over sshfs";
    assert expect "${name} ndh.sshfs.ownKey (as committed)" shared.ndh.sshfs.ownKey false;
    assert expect "${name} mount options (ownKey off)" (lib.unique (optionsOf shared)) [ today ];
    assert expect "${name} mount options (ownKey on)" (lib.unique (optionsOf owned)) [ owning ];
    # StrictHostKeyChecking=yes holds only where the authority vouches for the name: the seat's own names.
    assert lib.assertMsg (lib.elem cfg.remoteHost hostNames.${seat})
      "${name}: remoteHost ${cfg.remoteHost} is not one of ${seat}'s certified names (${toString hostNames.${seat}})";
    assert lib.assertMsg (lib.hasInfix "sshfsKeyFile=${lib.escapeShellArg sshfsKeyFile}" receiveText)
      "${name}: its ndh-identity-receive does not take the sshfs key, though it mounts sshfs";
    pkgs.runCommand "sshfs-mount-${name}" { } "touch $out";

  seatCheck =
    name: seat:
    let
      user = darwinConfigurations.${seat}.config.profile.user.name;
      line = "ssh-ed25519 AAAAtest ndh-sshfs-${name}";
      authorizedOf = c: c.environment.etc."ssh/nix_authorized_keys.d/${user}".text or "";
      sshfsLines = c: lib.filter (lib.hasInfix " ndh-sshfs-") (lib.splitString "\n" (authorizedOf c));
      shared = darwinConfigurations.${seat}.config;
      tested =
        (darwinConfigurations.${seat}.extendModules {
          modules = [ { ndh.sshfs.guestKeyLines = [ line ]; } ];
        }).config;
    in
    assert expect "${seat}: its sshfs key options" shared.ndh.sshfs.authorizedOptions sftpReadOnly;
    assert expect "${seat}: the sshfs key it authorizes, with a test public" (sshfsLines tested) [
      "${sftpReadOnly} ${line}"
    ];
    # As committed: none until keys.yaml records sshfs-<guest>, then only that one, read-only.
    assert expect "${seat}: the sshfs keys it authorizes, as committed" (sshfsLines shared) (
      map (l: "${sftpReadOnly} ${l}") shared.ndh.sshfs.guestKeyLines
    );
    assert lib.assertMsg (lib.all (lib.hasSuffix " ndh-sshfs-${name}") shared.ndh.sshfs.guestKeyLines)
      "${seat}: authorizes an sshfs key other than ${name}'s";
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
