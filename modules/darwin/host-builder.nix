{
  config,
  lib,
  ...
}:
let
  cfg = config.ndh.hostBuilder;
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
  # nikopol→nikopol-nixos. <host>-nixos already authorizes root over ssh
  # (root is a trusted nix user), so no builder key is deployed.
  #
  # See docs/host-builder-phases.adoc for the two-phase model and the
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
      'steady' turns the local linux-builder off and offloads to <host>-nixos.
    '';
    example = "steady";
  };

  config = lib.mkIf (cfg == "steady") {
    nix.distributedBuilds = true;
    nix.buildMachines = [
      {
        hostName = "${config.profile.host.hostName}-nixos";
        sshUser = "root";
        systems = [ "aarch64-linux" ];
        maxJobs = 8;
        protocol = "ssh-ng";
        supportedFeatures = [
          "big-parallel"
          "kvm"
          "nixos-test"
        ];
      }
    ];
    # The remote builder pulls dependencies straight from the binary caches
    # rather than having the Mac upload its whole closure over ssh.
    nix.settings.builders-use-substitutes = true;
  };
}
