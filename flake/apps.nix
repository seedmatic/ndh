{
  self,
  hostCatalog,
  catalogData,
  hostMainNameForProfile,
  baremetalLinkHosts,
  incusClusterJoinPackages,
  ndhBringupInstallerCommand,
  ndhLogCaptureCommand,
  ndhVmTartBootstrapInstallerAttr,
  inputs,
  mkBaremetalLinkDeploy,
  mkNdhBringupRuntimeInstaller,
  mkNdhLogCapturePackage,
  mkNdhVmTartBootstrapInstallerPackage,
  mkNixBuildObservePackage,
  ndhNixBashTrampolineDarwin,
  ndhStoreApiDarwin,
  pkgsFor,
  pkgsForDarwin,
  pkgsUnstableForDarwin,
  worktreePath,
  forAllSystems,
  nixpkgs,
}:
forAllSystems (
  system:
  let
    installer = mkNdhBringupRuntimeInstaller system;
    logCapture = mkNdhLogCapturePackage system;
    tartBootstrapInstaller = mkNdhVmTartBootstrapInstallerPackage system;
    # `apps.<system>` must be flat (each leaf is `{ type = "app"; … }`).
    # The Tart materializer is exposed under `packages.<system>` as
    # `nerd-tart-<host>-materialize` (its `meta.mainProgram` lets
    # `nix run .#nerd-tart-<host>-materialize` work), not duplicated here.
    hostBootstrapInstallerApps = builtins.foldl' (
      acc: hostName:
      let
        hostSpec = hostCatalog.${hostName};
        mainName = hostMainNameForProfile hostSpec.hostProfile;
      in
      acc
      // {
        "${mainName}-bringup-install" = {
          type = "app";
          program = "${installer}/bin/${ndhBringupInstallerCommand}";
          meta.description = "Install/refresh the NDH bringup-runtime nix profile for ${mainName} — src: modules/.common.d/bringup-runtime.d/";
        };
        "${mainName}-log-capture" = {
          type = "app";
          program = "${logCapture}/bin/${ndhLogCaptureCommand}";
          meta.description = "Capture ${mainName}'s build + activation logs (Vector telemetry) — src: flake.nix (mkNdhLogCapturePackage)";
        };
        "${mainName}-tart-vm-bootstrap-installer" = {
          type = "app";
          program = "${tartBootstrapInstaller}/bin/${ndhVmTartBootstrapInstallerAttr}";
          meta.description = "Install ${mainName}'s Tart NixOS bringup VM (disk image -> ZFS) — src: flake.nix (mkNdhVmTartBootstrapInstallerPackage)";
        };
      }
    ) { } (builtins.attrNames hostCatalog);
    baremetalLinkApps = builtins.foldl' (
      acc: bm:
      acc
      // {
        "${bm.domain}-baremetal-link-deploy" = {
          type = "app";
          program = "${mkBaremetalLinkDeploy system bm}/bin/${bm.domain}-baremetal-link-deploy";
          meta.description = "Install/refresh (or --uninstall) the baremetal-link LaunchDaemon on vzhost.${bm.domain} — src: pkgs/baremetal-link.d/";
        };
      }
    ) { } (builtins.attrValues baremetalLinkHosts);
    # listToAttrs, NOT mapAttrs: the recipe keys by bare domain, and mapAttrs would keep that
    # key — exposing the app as `nix run .#nikopol`, a name generic enough to collide.
    incusClusterJoinApps = builtins.listToAttrs (
      map (domain: {
        name = "${domain}-incus-cluster-join";
        value = {
          type = "app";
          program = "${incusClusterJoinPackages.${domain}}/bin/${domain}-incus-cluster-join";
          meta.description = "Join ${domain}-nixos to the Incus cluster, then pin it OUT of the raft (database-client) — src: pkgs/incus-cluster-join.d/";
        };
      }) (builtins.attrNames incusClusterJoinPackages)
    );
    nixBuildObservePackage = mkNixBuildObservePackage system;
    pkgsForSystem = pkgsFor { inherit system; };
    # check-jsonschema against keys.yaml AS COMMITTED — encrypted: the schema accepts
    # ENC[...] wherever a private may sit, so nothing is decrypted and no plaintext copy
    # is written. The same validation runs as checks.<system>.ssh-keys-schema and in the
    # pre-commit (treefmt keys-schema); this app checks an uncommitted keys.yaml, from the
    # repo root, with the tool named by revision:
    #   nix run "git+file://$PWD?rev=$(git rev-parse HEAD)#ssh-keys-v2-validate" -- <keys.yaml>
    sshKeysValidatorPackage = pkgsForSystem.writeShellApplication {
      name = "ssh-keys-v2-validate";
      runtimeInputs = [ pkgsForSystem.check-jsonschema ];
      text = ''
        target="''${1:-modules/home-manager/ssh.d/keys.yaml}"
        schema="modules/home-manager/ssh.d/keys.schema.yaml"
        if [[ ! -r "$schema" ]]; then
          echo "schema not found at $schema (run from repo root)" >&2
          exit 1
        fi
        if [[ ! -r "$target" ]]; then
          echo "target yaml not found: $target" >&2
          exit 1
        fi
        exec check-jsonschema --schemafile "$schema" "$target"
      '';
    };
    # The envs vendored under .flox-envs.d arrive WITHOUT their manifest.lock: fleet
    # gitignores it, and the lock is what makes an env includable — so a fresh clone
    # cannot activate the flox seat until this runs ("manifest and lockfile are out of sync").
    # The locks stay gitignored on purpose: fleet publishes manifests, each checkout
    # realises its own lock.
    #
    # The include graph is WALKED, not listed: `nix` includes `.../keyhole`, and a composed
    # env must be locked after the ones it includes. A hardcoded list rots the next time
    # fleet adds an include. Both quote styles are read because fleet writes the flox seat form
    # with double quotes and the internal form with single quotes.
    #
    # `flox` comes from the host (the flox installer), not nixpkgs —
    # writeShellApplication prepends runtimeInputs and keeps the inherited PATH.
    #
    # ⚠️ This is a SECOND copy — rke2lab's flake carries the same app. Its decided home is a
    # flake INSIDE the subtree, owned by fleet (`nix run ../.flox-envs.d#lock`): what it encodes
    # is fleet's own relative-include convention, so the producer should own it, and that route
    # adds no flake input edge. Moving it must delete rke2lab's copy in the same change, or two
    # copies become three.
    lockFloxEnvsPackage = pkgsForSystem.writeShellApplication {
      name = "lock-flox-envs";
      runtimeInputs = [
        pkgsForSystem.git
        pkgsForSystem.gnused
      ];
      text = ''
        cd "$(git rev-parse --show-toplevel)"

        declare -A walked=()

        deps_of() {
          sed -n -e "s|^[[:space:]]*{\? *dir = '\.\../\([^']*\)'.*|\1|p" \
                 -e 's|^[[:space:]]*{\? *dir = "\.\../\([^"]*\)".*|\1|p' "$1"
        }

        flox_seat_includes() {
          sed -n -e "s|^[[:space:]]*{\? *dir = '\../\.flox-envs\.d/\([^']*\)'.*|\1|p" \
                 -e 's|^[[:space:]]*{\? *dir = "\../\.flox-envs\.d/\([^"]*\)".*|\1|p' "$1"
        }

        lock_env() {
          local env="$1"
          local dir=".flox-envs.d/$env"
          if [ -n "''${walked[$env]:-}" ]; then
            return 0
          fi
          walked[$env]=1
          if [ ! -f "$dir/.flox/env/manifest.toml" ]; then
            echo "lock-flox-envs: no vendored env '$env' — is the subtree imported?" >&2
            exit 1
          fi
          local dep
          while read -r dep; do
            if [ -n "$dep" ]; then
              lock_env "$dep"
            fi
          done < <(deps_of "$dir/.flox/env/manifest.toml")
          if [ -f "$dir/.flox/env/manifest.lock" ]; then
            echo "  $env already locked"
          else
            echo "  locking $env"
            flox upgrade --dir "$dir" >/dev/null
          fi
        }

        # Refusing on zero is the point, not a guard against a typo: with no matches the
        # loop below simply never runs, and the success line still prints. The operator is
        # then told "ready" and `flox activate` fails with the very "manifest and lockfile
        # are out of sync" this app exists to prevent. A locker that cannot read the
        # manifest must SAY SO, not answer "nothing" — so this stays correct even for an
        # include form neither reader above anticipates.
        includes="$(flox_seat_includes .flox/env/manifest.toml)"
        if [ -z "$includes" ]; then
          echo "lock-flox-envs: no [include] entries under .flox-envs.d found in" >&2
          echo "  .flox/env/manifest.toml — refusing to report success." >&2
          exit 1
        fi

        while read -r env; do
          if [ -n "$env" ]; then
            lock_env "$env"
          fi
        done <<< "$includes"

        echo "vendored flox envs locked — 'flox activate' is ready"
      '';
    };
    # manage-tailnet: administer the tailnet (rotate auth keys / sync-policy /
    # retag / prune stale devices).  The recipe is extracted to package.nix
    # so it is exposed BOTH here (the app) and as packages.<system>.manage-tailnet
    # (for PATH consumers — the flox env, another flake's runtimeInputs).
    manageTailnetPackage = import ../modules/.common.d/manage-tailnet.d {
      pkgs = pkgsForSystem;
      catalog = catalogData;
      ndhStore = ndhStoreApiDarwin;
      nixBashTrampoline = ndhNixBashTrampolineDarwin;
    };
    bboxReconcilePackage = import ../modules/.common.d/bbox-reconcile.d/package.nix {
      pkgs = pkgsForSystem;
      lib = nixpkgs.lib;
      catalog = catalogData;
      inherit worktreePath;
    };
    # Operator ceremony: mint/rotate a self-signed TLS root for a keys.yaml
    # authority. Hermetic — every tool the script's preconditions name is
    # pinned here, so `nix run` works off any dev env. Runs from the repo cwd
    # (git rev-parse --show-toplevel), reading/re-encrypting keys.yaml in place.
    authorityBootstrapTlsRootPackage = pkgsForSystem.writeShellApplication {
      name = "authority-bootstrap-tls-root";
      runtimeInputs = [
        keysJsonPackage
        pkgsForSystem.git
        pkgsForSystem.step-cli
        pkgsForSystem.sops
        pkgsForSystem.yq-go
        pkgsForSystem.openssh
        pkgsForSystem.coreutils
      ];
      text = builtins.readFile ../modules/.common.d/authority-bootstrap-tls-root.d/authority-bootstrap-tls-root.sh;
    };
    # Operator ceremony: phase 1 of an SSH key renewal — add a dated slot to
    # selected keys.yaml entries and generate into it, so BOTH generations are
    # published while the fleet activates. Dry run unless --apply.
    #
    # ★ Generation happens HERE rather than by emptying a slot and letting
    # activation fill it: the enrichment runs against the sops-decrypted
    # RUNTIME copy, which is rewritten from the encrypted source on every
    # switch, so an empty slot in the source would be a different key after
    # every activation.
    # ★ Nothing is pinned by store path here, unlike its two siblings below:
    # sops, yq, ssh-keygen, git and the coreutils this needs are all part of
    # the bringup runtime profile's command contract, so the trampoline either
    # provides them or refuses with an install hint. `sops` was the one that
    # was NOT in that profile and had to come from the system closure — it is
    # in the contract now (53 MB of closure, measured).
    # keys.yaml's public view for nix, keys.json (modules/.common.d/keys-yaml.d/public.yq): rewritten by
    # the two programs below whenever they rewrite keys.yaml, and by hand after a manual edit.
    keysJsonPackage = import ../modules/.common.d/keys-yaml.d/json-tool.nix { pkgs = pkgsForSystem; };
    # The operator seat's own tools, one definition each: bioskop's configuration builds them (ndh-ops's tools).
    sshKeysRenewPackage = self.darwinConfigurations.bioskop.config.ndh.ndhSwitch.sshKeysRenew;
    # The fleet's nix signing key, replaced on the operator seat (the interim rotation of 2026-10-13).
    cacheSigningKeyRotatePackage = ndhStoreApiDarwin.installBinScript "cache-signing-key-rotate" (
      pkgsForSystem.replaceVars
        ../modules/.common.d/cache-signing-key-rotate.d/cache-signing-key-rotate.sh
        {
          nixBashTrampoline = ndhNixBashTrampolineDarwin;
          loggerTag = "ndh.cache-signing-key-rotate";
          nix = "${pkgsForSystem.nix}/bin/nix";
        }
    );
    sshKeysCertifyPackage = self.darwinConfigurations.bioskop.config.ndh.ndhSwitch.sshKeysCertify;
    # T14's closure: re-mint and install the Incus cluster certificate (one definition,
    # also packages.<system>.incus-cluster-cert-renew) — see its package.nix.
    # System-admin helper: prune darwin/HM/user generations + GC. Drives the
    # AMBIENT sudo + system nix daemon (a pinned nix would desync from it), so
    # runtimeInputs stays empty — writeShellApplication PREPENDS to PATH, it
    # does not reset it, so ambient tooling stays reachable.
    cleanupActivationsPackage = pkgsForSystem.writeShellApplication {
      name = "cleanup-activations";
      runtimeInputs = [ ];
      text = builtins.readFile ../modules/.common.d/cleanup-activations.d/cleanup-activations.sh;
    };
    # Temporary local vz linux-builder for the bootstrap phase (cold start,
    # no aarch64-linux builder yet). runtimeInputs carries ONLY the vz
    # builder (for `create-builder`) — NOT sudo: writeShellApplication
    # prepends to PATH, so the ambient setuid /usr/bin/sudo (the wrapper)
    # stays in reach for both this script and create-builder's own
    # install-credentials. Pinning a nixpkgs sudo would shadow it.
    # The stock vz builder boots tiny (1 vCPU / ~3 GiB RAM / 20 GiB store →
    # OOM and "no space left" on real closures). bioskop has ample RAM, so
    # bake a generous guest. These are read by the vz VM at build time
    # (nixos/modules/virtualisation/vz-vm.nix: cpuCount = cfg.cores,
    # memorySizeMiB = cfg.memorySize, dd seek = cfg.diskSize; cfg =
    # config.virtualisation.darwin-builder), so they must be set here, not
    # at runtime. diskSize is sparse (dd seek), so a large cap costs
    # nothing until used. mkForce overrides the profile defaults.
    bootstrapLinuxBuilderVz = pkgsUnstableForDarwin.darwin.linux-builder-vz.override {
      modules = [
        (
          { lib, ... }:
          {
            # cpuCount is read straight off virtualisation.cores (vz-vm.nix);
            # memorySize/diskSize are darwin-builder knobs that nix-builder.nix
            # maps onto virtualisation.memorySize / virtualisation.diskSize.
            virtualisation.cores = lib.mkForce 8;
            virtualisation.darwin-builder.memorySize = lib.mkForce 16384; # MiB (16 GiB)
            virtualisation.darwin-builder.diskSize = lib.mkForce 102400; # MiB (100 GiB, sparse)
          }
        )
      ];
    };
    bootstrapLinuxBuilderPackage = pkgsForSystem.writeShellApplication {
      name = "bootstrap-linux-builder";
      runtimeInputs = [ bootstrapLinuxBuilderVz ];
      text = builtins.readFile ../modules/.common.d/bootstrap-linux-builder.d/bootstrap-linux-builder.sh;
    };
  in
  {
    nix-build-observe = {
      type = "app";
      program = "${nixBuildObservePackage}/bin/nix-build-observe";
      meta.description = "Stream nix build telemetry to the observability sink — src: modules/darwin/bringup-observe.d/";
    };
    ssh-keys-v2-validate = {
      type = "app";
      program = "${sshKeysValidatorPackage}/bin/ssh-keys-v2-validate";
      meta.description = "Validate ssh keys.yaml against its JSON schema (sops-decrypts first) — src: modules/home-manager/ssh.d/keys.schema.yaml";
    };
    lock-flox-envs = {
      type = "app";
      program = "${lockFloxEnvsPackage}/bin/lock-flox-envs";
      meta.description = "Lock the flox envs vendored under .flox-envs.d so the flox seat can activate (fresh-clone bootstrap) — src: flake.nix (lockFloxEnvsPackage)";
    };
    # relock — nix-flake-commons' `lib.mkRelockApp`, the one implementation every seedmatic
    # flake shares. ndh supplies its name; the heads, the order and what each head pins are read
    # from nix-flake-commons:fabric/heads.
    relock = {
      type = "app";
      program = "${
        inputs.flake-commons.lib.mkRelockApp {
          pkgs = pkgsForSystem;
          name = "ndh";
        }
      }/bin/relock";
      meta.description = "Reconcile THIS head's locks: bump each input, DROP any bump that moves nothing it exports, push. --plan shows a pass, --downstream plays it over every head of fabric/heads";
    };
    manage-tailnet = {
      type = "app";
      program = "${manageTailnetPackage}/bin/manage-tailnet";
      meta.description = "Manage the tailnet: rotate per-kind Tailscale auth keys, reconcile the ACL, retag + prune stale devices (dry-run by default) — src: modules/.common.d/manage-tailnet.d/";
    };
    bbox-reconcile = {
      type = "app";
      program = "${bboxReconcilePackage}/bin/bbox-reconcile";
      meta.description = "Diff catalog.netplan.lan.hosts against the bbox /dhcp/clients reservations (read-only) — src: modules/.common.d/bbox-reconcile.d/";
    };
    authority-bootstrap-tls-root = {
      type = "app";
      program = "${authorityBootstrapTlsRootPackage}/bin/authority-bootstrap-tls-root";
      meta.description = "Mint/rotate a self-signed TLS root for a keys.yaml authority — <authority> [--force|--create <keyType>], run from repo root — src: modules/.common.d/authority-bootstrap-tls-root.d/";
    };
    ssh-keys-renew = {
      type = "app";
      program = "${sshKeysRenewPackage}/bin/ssh-keys-renew";
      meta.description = "Phase 1 of an SSH key renewal: add a dated slot and generate into it — [--key NAME] [--authority NAME] [--older-than Nd] [--apply], or declare a new entry with --create NAME --usage TAG (record a host key public from stdin with --public -), dry run by default, run from repo root — src: modules/.common.d/ssh-keys-renew.d/";
    };
    cache-signing-key-rotate = {
      type = "app";
      program = "${cacheSigningKeyRotatePackage}/bin/cache-signing-key-rotate";
      meta.description = "Replace the fleet's nix signing key on the operator seat: generate it, write it encrypted into catalog/cache-trust.yaml, print the new public — --to NAME [--apply], dry run by default, run from repo root — src: modules/.common.d/cache-signing-key-rotate.d/";
    };
    ssh-keys-certify = {
      type = "app";
      program = "${sshKeysCertifyPackage}/bin/ssh-keys-certify";
      meta.description = "Sign, on the operator seat, every SSH certificate keys.yaml declares (one host certificate per machine, its own names) and record them in keys.yaml — [--apply], dry run by default, run from repo root — src: modules/.common.d/ssh-keys-certify.d/";
    };
    sops-rekey = {
      type = "app";
      program = "${
        import ../modules/.common.d/sops.d/rekey.d/package.nix { pkgs = pkgsForSystem; }
      }/bin/sops-rekey";
      meta.description = "Re-seal every sops file to its .sops.yaml rule after a recipient change, then stage them — the operator's gesture (it opens each data key), run from repo root — src: modules/.common.d/sops.d/rekey.d/";
    };
    keys-json = {
      type = "app";
      program = "${keysJsonPackage}/bin/ndh-keys-json";
      meta.description = "Rewrite keys.json, keys.yaml's public view for nix, after a manual edit of keys.yaml — <keys.yaml>, run from repo root — src: modules/.common.d/keys-yaml.d/";
    };
    cleanup-activations = {
      type = "app";
      program = "${cleanupActivationsPackage}/bin/cleanup-activations";
      meta.description = "Prune nix-darwin/Home-Manager/user generations + GC (DRY_RUN=1 to preview) — src: modules/.common.d/cleanup-activations.d/";
    };
    bootstrap-linux-builder = {
      type = "app";
      program = "${bootstrapLinuxBuilderPackage}/bin/bootstrap-linux-builder";
      meta.description = "Cold-start: launch a temporary local vz linux-builder + wire the nix-daemon to it so `nixos-rebuild .#<host>-nixos` can build aarch64-linux (--stop to tear down) — src: modules/.common.d/bootstrap-linux-builder.d/";
    };
  }
  // hostBootstrapInstallerApps
  // baremetalLinkApps
  // incusClusterJoinApps
  # An operator seat tool, darwin only: the one definition is bioskop's ndh.incusClusterCert.package.
  // nixpkgs.lib.optionalAttrs (system == "aarch64-darwin") {
    # The armed delegation's runner: its tools are the very packages of their own apps, by store path.
    ndh-ops = {
      type = "app";
      program = "${self.darwinConfigurations.bioskop.config.ndh.ndhSwitch.ndhOps}/bin/ndh-ops";
      meta.description = "Run one of the operator's secret-reading tools on the delegation the operator armed (arm --hours N --tools a,b, operator only; status; disarm), every run logged — src: modules/.common.d/ndh-ops.d/";
    };
    incus-cluster-cert-renew = {
      type = "app";
      program = "${self.darwinConfigurations.bioskop.config.ndh.incusClusterCert.package}/bin/incus-cluster-cert-renew";
      meta.description = "Renew the Incus cluster certificate on the cluster's own key (a CSR signed on the operator seat), install it on every member, re-pin the operator seat client, verify — run from the seat, built by revision — src: modules/.common.d/incus-cluster-cert.d/";
    };
    ndh-canary-proven = {
      type = "app";
      program = "${
        import ../modules/nixos/secret-material-guard.d/canary-proven.d/package.nix {
          pkgs = pkgsForDarwin;
        }
      }/bin/ndh-canary-proven";
      meta.description = "Prove the in-guest secret-material canary at the checkout's revision and, only on a green build that refused the planted key, record its derivation (the record a bringup image is gated on) — run from a clean ndh checkout — src: modules/nixos/secret-material-guard.d/canary-proven.d/";
    };
    ndh-switch = {
      type = "app";
      program = "${self.darwinConfigurations.bioskop.config.ndh.ndhSwitch.package}/bin/ndh-switch";
      meta.description = "Switch ONE machine to a pushed revision merged into develop or main (github:seedmatic/ndh/<sha>), the sessions' only switch verb; refuses anything else and logs what it ran — run from darwin.bioskop — src: modules/.common.d/ndh-switch.d/";
    };
    fleet-switch = {
      type = "app";
      program = "${self.darwinConfigurations.bioskop.config.ndh.ndhSwitch.fleetSwitch}/bin/fleet-switch";
      meta.description = "Switch the fleet to ONE merged revision through ndh-switch, one machine at a time (NixOS guests, remote darwin hosts, the operator seat last and only with --with-seat), stopping at the first failure with the recovery; refuses to activate the seat when its activation would sign — run from darwin.bioskop — src: modules/.common.d/fleet-switch.d/";
    };
  }
)
