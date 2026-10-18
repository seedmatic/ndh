{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ndh.hostBuilder;
  capacity = config.ndh.builderCapacity;
  guest = "${config.profile.host.hostName}-nixos";
  # kvm is the INTENT: the guest has /dev/kvm when Tart launches it with --nested. The guest
  # advertises what the running VM really has (modules/nixos/nix-settings.nix), so a kvm build
  # sent while NESTED_VIRT=0 overrides it fails there instead of falling back to TCG.
  ownGuest = {
    hostName = "nix-store.${guest}";
    systems = [ "aarch64-linux" ];
    maxJobs = capacity.nixos.home;
    speedFactor = 1;
    supportedFeatures = [
      "big-parallel"
      "nixos-test"
    ]
    ++ lib.optional config.tart.configGenerator.vmRunNestedVirt "kvm";
  };
  # The builders sets ndh-builders switches between. A Mac builds its own darwin derivations itself: it is never
  # an entry of its own lists, since a build holds its output locks while the hook runs and a request to the same
  # store waits on them forever (nix 2.34 derivation-building-goal.cc; measured on nikopol, 2026-10-18).
  sets = {
    metalspace = [ ownGuest ];
  };
  # nix's machines file: uri, systems, ssh key, maxJobs, speedFactor, supported, mandatory, host key.
  line =
    m:
    lib.concatStringsSep " " [
      "ssh-ng://${m.hostName}"
      (lib.concatStringsSep "," m.systems)
      "-"
      (toString m.maxJobs)
      (toString m.speedFactor)
      (lib.concatStringsSep "," m.supportedFeatures)
      "-"
      "-"
    ];
  machines = "/etc/nix/machines";
  dir = "/var/lib/ndh/builders";
  defaultMode = "metalspace";
  ndhBuilders = pkgs.writeShellApplication {
    name = "ndh-builders";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      dir=${lib.escapeShellArg dir}
      machines=${lib.escapeShellArg machines}
      modes=${lib.escapeShellArg (lib.concatStringsSep " " (lib.attrNames sets))}
    ''
    + builtins.readFile ./host-builder.d/ndh-builders.sh;
  };
in
{
  # The aarch64-linux build scheme for a Darwin host, as a lifecycle phase:
  #
  #   bootstrap — a Darwin host has no NixOS sibling yet, so it builds
  #               aarch64-linux locally through the embedded QEMU
  #               linux-builder (baremetal only; see linux-builder.nix).
  #               This is the ONLY way to build+activate <host>-nixos the
  #               first time.
  #   steady    — <host>-nixos is up next door and also hosts incus, so it
  #               IS the aarch64-linux builder. The local linux-builder is
  #               turned off (it can't run on a VM host anyway); the Mac
  #               builds its darwin derivations itself and offloads Linux
  #               over ssh to the builders ndh-builders points at, pulling
  #               deps straight from the binary caches.
  #
  # The builder names are DERIVED from the host (config.profile.host.hostName),
  # not hardcoded, so the same knob offloads bioskop→bioskop-nixos and
  # nikopol→nikopol-nixos. The request goes through the `nix-store.<host>-nixos`
  # ssh alias (modules/.common.d/nix-store-identity.nix): the guest's nix-store
  # account, by its certificate, never root.
  #
  # See docs/host-builder-phases.adoc for the phases and the
  # promotion runbook.
  options.ndh.hostBuilder = lib.mkOption {
    type = lib.types.enum [
      "bootstrap"
      "steady"
    ];
    default = "bootstrap";
    description = ''
      aarch64-linux build phase for this Darwin host. 'bootstrap' uses the
      embedded linux-builder (baremetal) to first build <host>-nixos.
      'steady' turns the local linux-builder off and offloads to the builders
      ndh-builders points at (<host>-nixos by default).
    '';
    example = "steady";
  };

  config = lib.mkMerge [
    (lib.mkIf (cfg == "steady") {
      nixStoreIdentity.extraPeers = [ guest ];
      # No nix.buildMachines: nix-darwin then renders no list of its own, and the daemon reads the one
      # ndh-builders points at, from its next command.
      ndh.builderSets = sets;
      nix.settings.builders = "@${dir}/active";
      environment.etc = lib.mapAttrs' (
        mode: ms:
        lib.nameValuePair "nix/machines.${mode}" { text = lib.concatMapStrings (m: line m + "\n") ms; }
      ) sets;
      environment.systemPackages = [ ndhBuilders ];
      # A missing or dangling pointer is reset to the default; an existing choice is kept. Loud, never aborting:
      # nix-darwin's activate runs under set -e.
      system.activationScripts.postActivation.text = lib.mkAfter ''
        if ! ${ndhBuilders}/bin/ndh-builders >/dev/null 2>&1; then
          ${ndhBuilders}/bin/ndh-builders ${defaultMode} ||
            echo "[ndh-builders] FAILED at activation: no builders set, no Linux build runs until sudo ndh-builders ${defaultMode}" >&2
        fi
      '';
    })
    (lib.mkIf (cfg != "bootstrap") {
      nix.distributedBuilds = true;
      # The remote builder pulls dependencies straight from the binary caches
      # rather than having the Mac upload its whole closure over ssh.
      nix.settings.builders-use-substitutes = true;
    })
  ];
}
