{
  self,
  hostCatalog,
  catalogData,
  inputs,
  mkNdhBootstrapRuntimePackage,
  mkNdhBringupRuntimeInstaller,
  mkNdhDiskoPinnedModule,
  mkNdhLogCapturePackage,
  mkNdhStoreApiFor,
  mkNdhVmTartBootstrapInstallerPackage,
  mkNixBuildObservePackage,
  mkBaremetalLinkPackages,
  incusClusterJoinPackages,
  hostMainNameForProfile,
  ndhBringupRuntimeAttr,
  pkgsFor,
  ndhNixBashTrampolineDarwin,
  ndhNixBashTrampolineLinux,
  nixpkgs,
  ceremonyVm,
  darwinConfigurations,
  hostOutputs,
}:
nixpkgs.lib.genAttrs [ "aarch64-darwin" "aarch64-linux" ] (
  system:
  let
    ndhStoreApi = mkNdhStoreApiFor (pkgsFor {
      inherit system;
    });
    systemPkgs = pkgsFor { inherit system; };
    ndhNixBashTrampoline =
      if system == "aarch64-darwin" then ndhNixBashTrampolineDarwin else ndhNixBashTrampolineLinux;
  in
  # The keychain reconcile, buildable ON ITS OWN by revision: a fix between two
  # configurations ships as this closure, copied to the host and run by the operator
  # (`sudo ndh-keychain-reconcile` from the GUI session) — the same script the darwin
  # activation runs (modules/darwin/tls-authority-keychain.nix).
  nixpkgs.lib.optionalAttrs (system == "aarch64-darwin") {
    ndh-keychain-reconcile = self.darwinConfigurations.bioskop.config.ndh.tlsAuthorityKeychain.package;
    # T14, by the same rule: one closure built by revision, run from the operator seat.
    incus-cluster-cert-renew = self.darwinConfigurations.bioskop.config.ndh.incusClusterCert.package;
    # 2a′, its twin: the cache containers' TLS leaves.
  }
  # The vz-recover key's forced command, one per foreign vz-host: installed by the operator from a pushed
  # revision into that host's account profile, the path its authorized_keys line names. Its VMs are the
  # NixOS guest its darwin config materializes and the darwin guest, which Tart names after the metalspace.
  // nixpkgs.lib.optionalAttrs (system == "aarch64-darwin") (
    nixpkgs.lib.mapAttrs' (
      host: _:
      nixpkgs.lib.nameValuePair "${host}-vz-recover" (
        import ../pkgs/vz-recover.d/package.nix {
          pkgs = systemPkgs;
          inherit (nixpkgs) lib;
          vms = [
            {
              name = self.darwinConfigurations.${host}.config.tart.configGenerator.vmName;
              kind = "nixos";
            }
            {
              name = host;
              kind = "darwin";
            }
          ];
        }
      )
    ) (nixpkgs.lib.filterAttrs (_: bm: bm.vzHostKind == "foreign") catalogData.netplan.baremetal)
  )
  // {
    # manage-tailnet on PATH for BOTH systems (a packages output, not just the app):
    # rke2lab's flox-catalogue re-exports packages.aarch64-linux.manage-tailnet so the
    # in-cluster tailnet-purge Job installs it via a FloxEnv. Wired to the PER-SYSTEM
    # store API + trampoline so it builds on aarch64-linux too — the script is bash +
    # curl + yq, cross-platform. On aarch64-darwin these resolve to the same Darwin
    # helpers as before, so the darwin build is unchanged (same store path).
    manage-tailnet = import ../modules/.common.d/manage-tailnet.d {
      pkgs = systemPkgs;
      catalog = catalogData;
      ndhStore = ndhStoreApi;
      nixBashTrampoline = ndhNixBashTrampoline;
    };
    # The fork tailscale/tailscaled (CNAME extra_records + SSH port-2222)
    # as a first-class packages output — systemPkgs already has
    # tailscaleOverlay applied (see overlays/tailscale.nix), so this just
    # re-exports the patched build. rke2lab's flox-catalogue consumes
    # packages.aarch64-linux.tailscale so the in-cluster mesh tailscaled
    # runs the fork, matching the operator host.
    # The Incus CLI, for BOTH systems.  `pkgs.incus` is the full daemon and is Linux-only in
    # nixpkgs (it wants lxc, libcap, cowsql…), but nixpkgs ships a client-only variant as
    # `incus.passthru.client` that builds on Darwin too because it needs only Go and the
    # `cmd/incus` subpackage.  There is NO top-level `incus-client` attribute in our nixpkgs pin
    # — checked on both systems — so `passthru.client` is the route, not a workaround.
    #
    # ndh owns this rather than rke2lab, and that is the natural direction: ndh already owns the
    # incus DAEMON (modules/nixos/incus.nix, incus-cluster.nix) and the operator's trust to it
    # (modules/darwin/incus-remote-trust.nix), so the client belongs beside them. rke2lab
    # re-exports this package for its flox env, the same way ndh's manage-tailnet already
    # travels in that direction. Cross-referencing it the other way — ndh importing rke2lab's
    # client — would have the host layer borrow a tool from the cluster layer that runs ON it.
    incus-client = systemPkgs.incus.passthru.client;
    omo-patch = import ../modules/home-manager/omo-patch.d/package.nix { pkgs = systemPkgs; };
    inherit (systemPkgs) tailscale;
    ${ndhBringupRuntimeAttr} = mkNdhBootstrapRuntimePackage system;
    ndh-disko-module-pinned = mkNdhDiskoPinnedModule system;
    ndh-disko-config = ndhStoreApi.writeText "zfs-disko-config.nix" (
      builtins.readFile ../modules/nixos/zfs-disko-config.nix
    );
    nix-build-observe = mkNixBuildObservePackage system;
    # mDNS alias publisher used by the headscale-daemon modules to
    # advertise a fleet-scoped alias pointing at the current owner.
    # See packages/ndh-mdns-publish/{main.go,default.nix}.
    ndh-mdns-publish = systemPkgs.callPackage ../packages/ndh-mdns-publish { };
    # A builder's nix signing key, derived from its ssh host key (roles × keys B2).
    ndh-nix-signing-derive = systemPkgs.callPackage ../packages/ndh-nix-signing-derive { };
    # The root's ceremony VM, its argv fixed (roles × keys ⑧, docs/root-ceremony.adoc).
    ndh-ceremony-vm = systemPkgs.callPackage ../modules/darwin/ceremony-vm.d/package.nix {
      ceremony = ceremonyVm;
    };
  }
  // mkBaremetalLinkPackages system
  # Darwin only: the join is an operator act run from the operator's machine, and the recipe is
  # built against the Darwin store API. Exposed as packages too so it can be built and
  # dry-run'd on its own, not only through `nix run`.
  // nixpkgs.lib.optionalAttrs (system == "aarch64-darwin") (
    builtins.listToAttrs (
      map (domain: {
        name = "${domain}-incus-cluster-join";
        value = incusClusterJoinPackages.${domain};
      }) (builtins.attrNames incusClusterJoinPackages)
    )
  )
  // builtins.foldl' (
    acc: hostName:
    let
      hostSpec = hostCatalog.${hostName};
      mainName = hostMainNameForProfile hostSpec.hostProfile;
    in
    acc
    // {
      "${mainName}-bringup-install" = mkNdhBringupRuntimeInstaller system;
      "${mainName}-log-capture" = mkNdhLogCapturePackage system;
      "${mainName}-tart-vm-bootstrap-installer" = mkNdhVmTartBootstrapInstallerPackage system;
    }
  ) { } (builtins.attrNames hostCatalog)
  // nixpkgs.lib.optionalAttrs (system == "aarch64-darwin") (
    # Tart artifacts grouped by `nerd-tart-` prefix to make their
    # role obvious in `nix flake show`.  `packages.<system>` must be
    # flat (the flake schema rejects nested attrsets), so we use a
    # `nerd-tart-<host>-<role>` naming scheme:
    #   nerd-tart                    — generic, fleet-wide deploy bundle
    #   nerd-tart-<host>-config      — per-VM YAML manifest (scp to vz)
    #   nerd-tart-<host>-deploy      — operator helper: copy + activate on a REMOTE vz host
    #   nerd-tart-<host>-materialize — LOCAL materializer for the host that runs the VM
    # `-materialize` is the local counterpart of `-deploy`, and on a host that
    # runs the Tart VM itself (not a remote vz host) it is the ONLY entry point
    # to (re)materialize the VM — e.g.
    # `VM_FACTORY_RESET=true nix run .#nerd-tart-bioskop-materialize`.
    # Darwin activation deliberately never does this: staging the bringup images
    # is tens of GiB (see the `includeBringupSymlink` notes in
    # modules/darwin/tart-config.nix), and it has its own cadence, independent
    # of host convergence.  So the image stays out of the darwin system closure
    # and reaching it is an explicit operator gesture.
    let
      systemPkgs = pkgsFor { inherit system; };
      anyHostName = builtins.head (builtins.attrNames hostCatalog);
      anyHostDeploy =
        hostOutputs.${anyHostName}.darwinConfiguration.config.tart.configGenerator.deployPackage;
      mkDeployHelper =
        {
          mainName,
          vmName,
          runManifest,
          # The host's OWN bringup images: their third store layer is the host's runtime
          # residue, so another host's images would boot another host's system.
          bringupImages,
        }:
        systemPkgs.writeShellApplication {
          name = "nerd-tart-${mainName}-deploy";
          runtimeInputs = [
            systemPkgs.nix
            systemPkgs.openssh
          ];
          text = ''
            set -euo pipefail

            # Default vz host: by convention every Tart VM has a
            # matching `vzhost.<mainName>` ssh alias on the operator's
            # home-manager (see modules/home-manager/ssh-tailnet-hosts.nix).
            # Override by passing a host as the first positional argument.
            vz_host="vzhost.${mainName}"
            if (($# > 0)) && [[ "$1" != --* ]]; then
              vz_host="$1"
              shift
            fi

            case "''${1:-}" in
              -h|--help)
                cat >&2 <<-USAGE
            Usage: nerd-tart-${mainName}-deploy [vz-host] [-- extra tart run args]

            Copies the generic Tart deploy bundle, the ${mainName}-specific
            per-VM YAML, and ${mainName}'s bringup disk images to <vz-host>
            (default: vzhost.${mainName}); installs the YAML at
            ~/.config/nerd-tart/${mainName}.yaml on the vz host; then execs
            nerd-tart there to materialize and run the VM.
            USAGE
                exit 0
                ;;
            esac

            deploy_bundle=${anyHostDeploy}
            vm_config=${runManifest}
            bringup_images=${bringupImages}

            # Pull, don't push.  The operator host (e.g. bioskop) and
            # the bare-metal vz host share a LAN, while `vzhost.<host>`
            # routes through the Tart guest via ProxyJump — a
            # single-stream ssh tunnel that throttles disk-image
            # transfer to ~600 KB/s and traverses the bare metal's
            # network stack twice.  Inverting the direction lets
            # vz_host pull straight from the operator over mDNS,
            # which is the LAN-direct path.
            #
            # Source URL is `ssh-ng://$USER@<src>.local`, not the
            # cert-bound `nix-store.<peer>` alias from
            # modules/.common.d/nix-store-identity.nix: vz hosts are
            # bare-metal Macs outside the fleet inventory, so the
            # nix-store-identity ssh client fragment isn't generated
            # there.  Plain mDNS + the operator's normal ssh key is
            # what's reliably available.  `--no-check-sigs` covers
            # the case where vz_host's nix.conf doesn't trust the
            # fleet signing key (drift can leave the catalog stale
            # on a vz host that hasn't been rebuilt recently).
            src_host="$(hostname -s)"
            src_url="ssh-ng://$USER@$src_host.local"
            echo "[nerd-tart-deploy] pulling artifacts on $vz_host from $src_url" >&2
            # shellcheck disable=SC2029
            ssh "$vz_host" \
              "nix copy --no-check-sigs --from '$src_url' \
                 '$deploy_bundle' '$vm_config' '$bringup_images'"

            echo "[nerd-tart-deploy] installing per-VM YAML on $vz_host" >&2
            # `$vm_config` is intentionally expanded client-side: it
            # holds the local store path, which has just been copied
            # to the vz host's nix store and is now valid there too.
            # The symlink basename must match the wrapper basename
            # at ~/.tart/vms/<vmName>.sh, since run.sh resolves the
            # manifest by `basename "$0" .sh`.  vmName is the Tart
            # VM directory name (default "nerd-nixos") and is
            # distinct from mainName (the host-catalog key).
            # shellcheck disable=SC2029
            ssh "$vz_host" \
              "mkdir -p ~/.config/nerd-tart && \
               ln -sfn '$vm_config' ~/.config/nerd-tart/${vmName}.yaml"

            echo "[nerd-tart-deploy] activating nerd-tart on $vz_host" >&2
            exec ssh -t "$vz_host" "$deploy_bundle/bin/nerd-tart" \
              --config "$vm_config" "$@"
          '';
        };
      tartAttrs = builtins.foldl' (
        acc: hostName:
        let
          hostSpec = hostCatalog.${hostName};
          mainName = hostMainNameForProfile hostSpec.hostProfile;
          hostOutput = hostOutputs.${hostName};
          runManifest = hostOutput.darwinConfiguration.config.tart.configGenerator.runManifest;
        in
        acc
        // {
          "nerd-tart-${mainName}-config" = runManifest;
          "nerd-tart-${mainName}-deploy" = mkDeployHelper {
            inherit mainName runManifest;
            vmName = hostOutput.darwinConfiguration.config.tart.configGenerator.vmName;
            bringupImages = hostOutput.nixosDiskImageBringupSystemdZfs;
          };
          "nerd-tart-${mainName}-materialize" =
            hostOutput.darwinConfiguration.config.tart.configGenerator.materializerPackage;
        }
      ) { } (builtins.attrNames hostCatalog);
      # Single fleet-wide deploy bundle — identical for every host that
      # runs Tart, so we pick an arbitrary host's deployPackage.  The
      # underlying derivation depends only on host-agnostic inputs (the
      # bringup image and the activation/run scripts).
    in
    tartAttrs
    // {
      nerd-tart = anyHostDeploy;
      # manage-tailnet moved to the common (both-systems) body above — it now builds
      # for aarch64-linux too (per-system store API + trampoline), so the darwin-only
      # copy here is gone.
    }
  )
  // nixpkgs.lib.optionalAttrs (system == "aarch64-linux") (
    # One bringup disk-image set PER HOST: the third store layer is the host's runtime residue
    # (see modules/nixos/bringup-zfs-disk-image.nix), so the sets are no longer bit-identical
    # across hosts, and an arbitrary host's set boots that host's system.
    builtins.listToAttrs (
      map (hostName: {
        name = "nerd-nixos-${
          hostMainNameForProfile hostCatalog.${hostName}.hostProfile
        }-bringup-zfs-systemd-disk";
        value = hostOutputs.${hostName}.nixosDiskImageBringupSystemdZfs;
      }) (builtins.attrNames hostCatalog)
    )
  )
)
