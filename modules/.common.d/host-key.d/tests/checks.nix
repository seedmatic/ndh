# What sshd serves, read from the evaluated configurations: no NixOS configuration generates a host key,
# and every guest and operator seat serves exactly the key ndh.hostKey.own says, with its certificate.
# own = true is evaluated on each machine with a test certificate: keys.yaml holds none until the
# operator records them, and ndh.hostKey.certificate is otherwise read from it.
{
  pkgs,
  pkgsForLinux,
  lib,
  nixosConfigurations,
  darwinConfigurations,
  guests,
  seats,
}:
let
  testCertificate = "ssh-ed25519-cert-v01@openssh.com AAAAtest host-test";
  owning =
    system:
    (system.extendModules {
      modules = [
        {
          ndh.hostKey = {
            own = true;
            certificate = testCertificate;
          };
        }
      ];
    }).config;
  linesOf = keyword: text: lib.filter (lib.hasPrefix "${keyword} ") (lib.splitString "\n" text);
  expect =
    what: actual: wanted:
    lib.assertMsg (
      actual == wanted
    ) "${what}: ${builtins.toJSON actual}, expected ${builtins.toJSON wanted}";

  guest =
    name:
    let
      shared = nixosConfigurations.${name}.config;
      owned = owning nixosConfigurations.${name};
      units = c: c.systemd.services;
      copiesRdpHost =
        c:
        lib.any (lib.hasInfix "openssh-sshd-host-identity-reload") (
          lib.toList ((units c)."home-manager-${c.profile.user.name}".serviceConfig.ExecStartPost or [ ])
        );
    in
    assert expect "${name} HostKey (own = false)"
      (linesOf "HostKey" shared.services.openssh.extraConfig)
      [
        "HostKey /etc/ssh/ssh_host_ed25519_key"
      ];
    assert expect "${name} HostCertificate (own = false)"
      shared.services.openssh.settings.HostCertificate
      shared.sshPaths.hostCertPublic;
    assert lib.assertMsg (
      (units shared) ? "io-seedmatic-ndh-hostkey-enrollment-check" && copiesRdpHost shared
    ) "${name} (own = false): the rdp-host copy or its enrollment check is not wired";
    assert lib.assertMsg (
      !((units shared) ? "io-seedmatic-ndh-host-key-check")
    ) "${name} (own = false): the owned-key check is wired";
    assert expect "${name} hostKeys (own = true)" owned.services.openssh.hostKeys [ ];
    assert expect "${name} HostKey (own = true)" (linesOf "HostKey" owned.services.openssh.extraConfig)
      [
        "HostKey ${owned.ndh.hostKey.file}"
      ];
    assert expect "${name} HostCertificate (own = true)" owned.services.openssh.settings.HostCertificate
      "${owned.ndh.hostKey.certificateFile}";
    assert lib.assertMsg
      (lib.hasPrefix builtins.storeDir owned.services.openssh.settings.HostCertificate)
      "${name} (own = true): HostCertificate is not a store file";
    assert lib.assertMsg (
      !((units owned) ? "io-seedmatic-ndh-hostkey-enrollment-check") && !(copiesRdpHost owned)
    ) "${name} (own = true): the rdp-host copy or its enrollment check is still wired";
    assert expect "${name} host-key-check requiredBy (own = true)"
      (units owned)."io-seedmatic-ndh-host-key-check".requiredBy
      [ "sshd.service" ];
    # The sandbox has no placed key: the check must fail, naming the file and the gesture.
    pkgsForLinux.runCommand "host-key-served-${name}" { } ''
      if ${owned.ndh.hostKey.check} 2>err; then
        echo "the host-key check passed without ${owned.ndh.hostKey.file}" >&2
        exit 1
      fi
      grep -qF ${lib.escapeShellArg owned.ndh.hostKey.file} err
      grep -qF "ndh-identity-push ${owned.networking.hostName}" err
      touch $out
    '';

  seat =
    name:
    let
      shared = darwinConfigurations.${name}.config;
      owned = owning darwinConfigurations.${name};
      dropIn = c: c.environment.etc."ssh/sshd_config.d/999-ndh.conf".text;
    in
    assert expect "${name} HostKey (own = false)" (linesOf "HostKey" (dropIn shared)) [
      "HostKey ${shared.sshPaths.privKeyFile}"
    ];
    assert expect "${name} HostCertificate (own = false)" (linesOf "HostCertificate" (dropIn shared)) [
      "HostCertificate ${shared.sshPaths.secretsKeysDir}/${builtins.baseNameOf shared.sshPaths.privKeyFile}-server-cert.pub"
    ];
    assert expect "${name} HostKey (own = true)" (linesOf "HostKey" (dropIn owned)) [
      "HostKey ${owned.ndh.hostKey.file}"
    ];
    assert expect "${name} HostCertificate (own = true)" (linesOf "HostCertificate" (dropIn owned)) [
      "HostCertificate ${owned.ndh.hostKey.certificateFile}"
    ];
    assert lib.assertMsg
      # Without context: hasInfix builds a regex from the needle, and a regex may not name a store path.
      (lib.hasInfix (builtins.unsafeDiscardStringContext "${owned.ndh.hostKey.check}") (
        builtins.unsafeDiscardStringContext owned.system.activationScripts.etc.text
      ))
      "${name} (own = true): the activation does not report a missing host key";
    pkgs.runCommand "host-key-served-${name}" { } "touch $out";
in
{
  # NixOS generates every services.openssh.hostKeys entry at boot: none, on every configuration.
  sshd-generates-no-host-key =
    let
      generating = lib.attrNames (
        lib.filterAttrs (_: system: system.config.services.openssh.hostKeys != [ ]) nixosConfigurations
      );
    in
    assert lib.assertMsg (
      generating == [ ]
    ) "services.openssh.hostKeys is not empty on: ${lib.concatStringsSep ", " generating}";
    pkgs.runCommand "sshd-generates-no-host-key" { } "touch $out";

  # ndh.hostKey.certificate's lookup: the newest slot's, under the entry's authority; none refuses.
  host-key-certificate =
    let
      certificateOf = import ../certificate.nix { inherit lib; };
      entry = {
        authority = "fabric";
        slots = {
          "26-05-29".certificates.fabric.ssh-host = "OLD";
          "26-10-16".certificates.fabric.ssh-host = "NEW";
        };
      };
      refused = keys: !(builtins.tryEval (certificateOf keys "m")).success;
    in
    assert expect "the newest slot's certificate" (certificateOf { host-m = entry; } "m") "NEW";
    assert lib.assertMsg (refused { }) "a machine with no host-<machine> entry evaluated";
    assert lib.assertMsg (refused {
      host-m = entry // {
        slots = entry.slots // {
          "26-11-01".public = "AAAA";
        };
      };
    }) "a newest slot without its certificate evaluated to an older one";
    assert lib.assertMsg (refused {
      host-m = entry // {
        authority = "other";
      };
    }) "a certificate under another authority was taken";
    pkgs.runCommand "host-key-certificate" { } "touch $out";
}
// lib.listToAttrs (map (name: lib.nameValuePair "host-key-served-${name}" (guest name)) guests)
// lib.listToAttrs (map (name: lib.nameValuePair "host-key-served-${name}" (seat name)) seats)
