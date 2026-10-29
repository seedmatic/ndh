# What sshd serves, read from the evaluated configurations: no NixOS configuration generates a host key,
# and every guest and operator seat serves exactly the key ndh.hostKey.own says, with its certificate.
# Both values of ndh.hostKey.own are reached on each machine through its slot state (own is read from it, K5): a
# serving slot with a test certificate, as keys.yaml holds none for a machine whose key is not recorded yet, and
# ndh.hostKey.certificate is otherwise read from it; a recorded one for the other side.
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
  sharing = withSlot "recorded" "keyring" { };
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
      shared = sharing nixosConfigurations.${name};
      owned = owning nixosConfigurations.${name};
      units = c: c.systemd.services;
      copiesRdpHost =
        c:
        lib.any (lib.hasInfix "openssh-sshd-host-identity-reload") (
          lib.toList ((units c)."home-manager-${c.profile.user.name}".serviceConfig.ExecStartPost or [ ])
        );
      # What Tailscale SSH reads, which sshd's HostKey does not govern.
      etcSshRules = c: lib.filter (lib.hasInfix " /etc/ssh/ssh_host_") c.systemd.tmpfiles.rules;
      restartsTailscaledOn =
        c:
        lib.elem (builtins.toJSON { inherit (c.ndh.hostKey) own file; }) (
          (units c).tailscaled.restartTriggers or [ ]
        );
      reloadScript = lib.last (
        lib.splitString " " (
          lib.findFirst (lib.hasInfix "openssh-sshd-host-identity-reload") (throw "${name}: no rdp-host copy")
            (lib.toList (units shared)."home-manager-${shared.profile.user.name}".serviceConfig.ExecStartPost)
        )
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
    assert expect "${name} /etc/ssh tmpfiles rules (own = false)" (etcSshRules shared) [ ];
    assert lib.assertMsg (restartsTailscaledOn shared)
      "${name} (own = false): tailscaled does not restart on the own state";
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
    assert lib.assertMsg (
      !((units owned) ? "io-seedmatic-ndh-hostkey-enrollment-check") && !(copiesRdpHost owned)
    ) "${name} (own = true): the rdp-host copy or its enrollment check is still wired";
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
      # The rdp-host copy restarts tailscaled from install_host_key, after its unchanged-key return.
      sed -n '/^install_host_key()/,/^}/p' ${reloadScript} >install
      grep -n 'cmp -s' install | head -1 | cut -d: -f1 >cmp
      grep -nx '  restart_tailscaled' install | cut -d: -f1 >restart
      [[ -s cmp && -s restart && $(cat restart) -gt $(cat cmp) ]]
      touch $out
    '';

  seat =
    name:
    let
      shared = sharing darwinConfigurations.${name};
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
    assert lib.assertMsg (refused { }) "a machine with no <machine> entry evaluated";
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
