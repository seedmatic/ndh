{
  config,
  lib,
  ndh,
  pkgs,
  ...
}:
let
  cfg = config.ndh.hostBuilder;
  capacity = config.ndh.builderCapacity;
  self' = config.profile.host.hostName;
  guestOf = host: "${host}-nixos";
  guest = guestOf self';
  # The other metalspaces: one darwin host each in the inventory, with its NixOS guest.
  others = lib.filter (h: h != self') (
    lib.attrNames (lib.attrByPath [ "context" "inventory" "hosts" ] { } ndh)
  );
  # kvm is the INTENT: the guest has /dev/kvm when Tart launches it with --nested. The guest
  # advertises what the running VM really has (modules/nixos/nix-settings.nix), so a kvm build
  # sent while NESTED_VIRT=0 overrides it fails there instead of falling back to TCG.
  guestFeatures = [
    "big-parallel"
    "nixos-test"
  ];
  ownGuest = {
    hostName = "nix-store.${guest}";
    systems = [ "aarch64-linux" ];
    maxJobs = capacity.nixos.home;
    supportedFeatures = guestFeatures ++ lib.optional config.tart.configGenerator.vmRunNestedVirt "kvm";
  };
  # nix ranks the machines with a free slot by busy slots / speedFactor (build-remote.cc): home wins while both
  # are idle, and an idle peer wins as soon as home has one build running (1/10 > 0/1). The operator accepted that
  # order (2026-10-18); `ndh-builders metalspace`, the default, leaves the peers out.
  home = 10;
  peer = 1;
  # The Mac's own system-features (nix's darwin default, not set in ndh).
  darwinFeatures = [
    "apple-virt"
    "benchmark"
    "big-parallel"
    "nixos-test"
  ];
  loopback = {
    hostName = "nix-store.${self'}";
    systems = [ "aarch64-darwin" ];
    maxJobs = capacity.darwin.home;
    supportedFeatures = darwinFeatures;
    speedFactor = home;
  };
  peerMac = host: {
    hostName = "nix-store.${host}";
    systems = [ "aarch64-darwin" ];
    maxJobs = capacity.darwin.peer;
    supportedFeatures = darwinFeatures;
    speedFactor = peer;
  };
  # Another metalspace's guest: its launch-time kvm is not known here, so no kvm build goes to it.
  peerGuest = host: {
    hostName = "nix-store.${guestOf host}";
    systems = [ "aarch64-linux" ];
    maxJobs = capacity.nixos.peer;
    supportedFeatures = guestFeatures;
    speedFactor = peer;
  };
  sets = rec {
    metalspace = [
      loopback
      (ownGuest // { speedFactor = home; })
    ];
    fabric = metalspace ++ map peerMac others ++ map peerGuest others;
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
  #               turned off (it can't run on a VM host anyway) and the Mac
  #               offloads to <host>-nixos over ssh, pulling deps straight
  #               from the binary caches instead of uploading its closure.
  #
  # The buildMachine name is DERIVED from the host (config.profile.host.hostName),
  # not hardcoded, so the same knob offloads bioskop→bioskop-nixos and
  # nikopol→nikopol-nixos. The request goes through the `nix-store.<host>-nixos`
  # ssh alias (modules/.common.d/nix-store-identity.nix): the guest's nix-store
  # account, by its certificate, never root.
  #
  #   requests  — every build is a request (roles × keys B3, variant A): the
  #               Mac builds nothing itself (max-jobs = 0). Its own darwin
  #               builds go through ssh-ng to its own nix-store account (the
  #               loopback), its Linux builds to its guest. `ndh-builders
  #               fabric` adds the other metalspace's Mac and guest, over
  #               the tailnet; `metalspace`, the default, leaves them out.
  #
  # See docs/host-builder-phases.adoc for the phases and the
  # promotion runbook.
  options.ndh.hostBuilder = lib.mkOption {
    type = lib.types.enum [
      "bootstrap"
      "steady"
      "requests"
    ];
    default = "bootstrap";
    description = ''
      aarch64-linux build phase for this Darwin host. 'bootstrap' uses the
      embedded linux-builder (baremetal) to first build <host>-nixos.
      'steady' turns the local linux-builder off and offloads to <host>-nixos.
      'requests' builds nothing locally: its own darwin builds through the
      loopback; ndh-builders chooses whether the other metalspace's builders
      are used too.
    '';
    example = "steady";
  };

  config = lib.mkMerge [
    (lib.mkIf (cfg == "steady") {
      nixStoreIdentity.extraPeers = [ guest ];
      nix.buildMachines = [ (ownGuest // { protocol = "ssh-ng"; }) ];
    })
    (lib.mkIf (cfg == "requests") {
      nixStoreIdentity = {
        selfAlias = true;
        extraPeers = [ guest ] ++ map guestOf others;
        tailnetPeers = others ++ map guestOf others;
      };
      nix.settings.max-jobs = 0;
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
            echo "[ndh-builders] FAILED at activation: no builders set, every build fails until sudo ndh-builders ${defaultMode}" >&2
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
