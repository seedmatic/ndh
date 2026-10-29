# What sshd serves, read from the evaluated configurations: every guest and operator seat serves its own host key
# (rdp-host retired, 2026-10-29), with its certificate, reached through a serving slot given a test certificate.
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
  # ndh.hostKey.own is read from the slot state (K5): each side is reached by giving the machine a host-key entry whose
  # current slot is, or is not, `serving`.
  withSlot =
    state: origin: extra: system:
    (system.extendModules {
      modules = [
        {
          ndh.hostKey = {
            entry = lib.mkForce {
              slots."26-01-01" = {
                inherit state origin;
              };
            };
          }
          // extra;
        }
      ];
    }).config;
  owning = withSlot "serving" "keyring" { certificate = testCertificate; };
  # A key born on the machine (K3) and certified by the window: served where it was generated, in its slot's directory.
  born = withSlot "serving" "host" { certificate = testCertificate; };
  servesBornKeyFromItsSlot =
    name: c:
    let
      wanted = "${c.ndh.hostKey.slotDir}/26-01-01/ssh_host_ed25519_key";
    in
    lib.assertMsg (
      c.ndh.hostKey.file == wanted
    ) "${name}: a born, serving key is served from ${c.ndh.hostKey.file}, not from its slot ${wanted}";
  linesOf = keyword: text: lib.filter (lib.hasPrefix "${keyword} ") (lib.splitString "\n" text);
  expect =
    what: actual: wanted:
    lib.assertMsg (
      actual == wanted
    ) "${what}: ${builtins.toJSON actual}, expected ${builtins.toJSON wanted}";

  guest =
    name:
    let
      owned = owning nixosConfigurations.${name};
      units = c: c.systemd.services;
      # What Tailscale SSH reads, which sshd's HostKey does not govern.
      etcSshRules = c: lib.filter (lib.hasInfix " /etc/ssh/ssh_host_") c.systemd.tmpfiles.rules;
      restartsTailscaledOn = c: lib.elem c.ndh.hostKey.file ((units c).tailscaled.restartTriggers or [ ]);
    in
    assert servesBornKeyFromItsSlot name (born nixosConfigurations.${name});
    assert expect "${name} HostKey (born, own = true)"
      (linesOf "HostKey" (born nixosConfigurations.${name}).services.openssh.extraConfig)
      [
        "HostKey ${(born nixosConfigurations.${name}).ndh.hostKey.slotDir}/26-01-01/ssh_host_ed25519_key"
      ];
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
    assert expect "${name} host-key-check requiredBy (own = true)"
      (units owned)."io-seedmatic-ndh-host-key-check".requiredBy
      [ "sshd.service" ];
    assert expect "${name} /etc/ssh tmpfiles rules (own = true)" (etcSshRules owned) [
      "L+ /etc/ssh/ssh_host_ed25519_key - - - - ${owned.ndh.hostKey.file}"
      "r /etc/ssh/ssh_host_ed25519_key.pub - - - - -"
      "r /etc/ssh/ssh_host_rsa_key - - - - -"
      "r /etc/ssh/ssh_host_rsa_key.pub - - - - -"
      "r /etc/ssh/ssh_host_ecdsa_key - - - - -"
      "r /etc/ssh/ssh_host_ecdsa_key.pub - - - - -"
    ];
    assert lib.assertMsg (restartsTailscaledOn owned)
      "${name} (own = true): tailscaled does not restart on the own state";
    assert lib.assertMsg (
      !(lib.any (
        p:
        lib.elem (lib.getName p) [
          "ndh-identity-reload"
          "ndh-identity-receive"
        ]
      ) owned.environment.systemPackages)
    ) "${name}: a push receiver is still installed (K5 deleted the push channel)";
    # The sandbox has no placed key: the check must fail, naming the file and the gesture.
    pkgsForLinux.runCommand "host-key-served-${name}" { } ''
      if ${owned.ndh.hostKey.check} 2>err; then
        echo "the host-key check passed without ${owned.ndh.hostKey.file}" >&2
        exit 1
      fi
      grep -qF ${lib.escapeShellArg owned.ndh.hostKey.file} err
      grep -qF "ops next" err
      touch $out
    '';

  seat =
    name:
    let
      owned = owning darwinConfigurations.${name};
      dropIn = c: c.environment.etc."ssh/sshd_config.d/999-ndh.conf".text;
    in
    assert expect "${name} HostKey (own = true)" (linesOf "HostKey" (dropIn owned)) [
      "HostKey ${owned.ndh.hostKey.file}"
    ];
    assert servesBornKeyFromItsSlot name (born darwinConfigurations.${name});
    assert expect "${name} HostKey (born, own = true)"
      (linesOf "HostKey" (dropIn (born darwinConfigurations.${name})))
      [
        "HostKey ${(born darwinConfigurations.${name}).ndh.hostKey.slotDir}/26-01-01/ssh_host_ed25519_key"
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
  # NixOS generates every services.openssh.hostKeys entry at boot: none on a fleet machine, which serves its own;
  # exactly one ed25519 on a configuration that is no catalog machine (the generic runtime, the bringup alias).
  sshd-generates-no-host-key =
    let
      generating = lib.attrNames (
        lib.filterAttrs (
          _: system: system.config.ndh.hostKey.own && system.config.services.openssh.hostKeys != [ ]
        ) nixosConfigurations
      );
    in
    assert lib.assertMsg (generating == [ ])
      "services.openssh.hostKeys is not empty on a machine serving its own key: ${lib.concatStringsSep ", " generating}";
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
    assert expect "the newest slot's certificate" (certificateOf { m = entry; } "m") "NEW";
    assert lib.assertMsg (refused { }) "a machine with no <machine> entry evaluated";
    assert lib.assertMsg (refused {
      m = entry // {
        slots = entry.slots // {
          "26-11-01".public = "AAAA";
        };
      };
    }) "a newest slot without its certificate evaluated to an older one";
    assert lib.assertMsg (refused {
      m = entry // {
        authority = "other";
      };
    }) "a certificate under another authority was taken";
    pkgs.runCommand "host-key-certificate" { } "touch $out";
}
// lib.listToAttrs (map (name: lib.nameValuePair "host-key-served-${name}" (guest name)) guests)
// lib.listToAttrs (map (name: lib.nameValuePair "host-key-served-${name}" (seat name)) seats)
