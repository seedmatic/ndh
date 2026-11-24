{
  canaryProven,
  catalogData,
  inventoryData,
  darwin,
  home-manager,
  nixpkgs,
  mkDarwinOutputs,
  mkNdhBootstrapRuntimePackage,
  mkNdhBringupRuntimeInstaller,
  mkNdhHomeManagerSpecialArgs,
  mkNdhVmTartBootstrapInstallerPackage,
  mkNixosOutputs,
  pkgsForDarwin,
  ndhBringupInstallerAttr,
  ndhBringupInstallerCommand,
  ndhBringupRuntimeAttr,
  ndhNixBashTrampolineDarwin,
  ndhStoreApiDarwin,
  ndhVmTartBootstrapInstallerAttr,
  ndhVmTartMaterializeAttr,
  pkgsForLinux,
  self,
  worktreePath,
}:
{
  hostProfile,
  profileModule,
  darwinExtraModules ? [ ],
  nixosExtraModules ? [ ],
  pauseAfterInstall ? false,
  enableBuildObserve ? false,
  buildObserveInterval ? 5,
  linuxBuilderGcBeforeBuild ? true,
  ...
}:
let
  mainName =
    if (hostProfile ? hostAlias && hostProfile.hostAlias != null && hostProfile.hostAlias != "") then
      hostProfile.hostAlias
    else
      hostProfile.hostName;
  catalog = catalogData;

  # HM user identity, augmented with a resolved home directory.
  homeManagerUserWithHome = catalog.user // {
    home =
      if catalog.user ? home && catalog.user.home != null then
        catalog.user.home
      else
        "/Users/${catalog.user.name}";
  };
  hostUserProfile = {
    host = hostProfile;
    user = homeManagerUserWithHome;
    email = homeManagerUserWithHome.email;
  };
  nixosOutputs = mkNixosOutputs {
    inherit hostProfile catalog;
    inventory = inventoryData;
    inherit pauseAfterInstall enableBuildObserve buildObserveInterval;
    profileModule =
      { ... }:
      {
        imports = [ profileModule ] ++ nixosExtraModules;
      };
  };
  nixosConfiguration = nixosOutputs.nixosConfigurations."${mainName}-bringup";
  nixosDiskImage = nixosOutputs.diskImageFull;
  nixosDiskImageBringupSystemd = nixosOutputs.diskImageBringupSystemdBoot;
  # A bringup image ships only on a guard proven at its current derivation (🛡️, 2026-10-24): the in-guest canary
  # left the default checks, so its last green run is recorded, and an image whose canary moved since refuses
  # to evaluate, naming the run that proves it again. Every image route (packages, nixosDiskImages, the tart
  # deploy and materialize bundles) goes through this one binding.
  nixosDiskImageBringupSystemdZfs = canaryProven nixosOutputs.diskImageBringupZfsSystemdBootUngated;
  nixosBringupSecretCanaryBuild = nixosOutputs.bringupSecretCanaryBuild;
  nixosDiskImageBringupGrub = nixosOutputs.diskImageBringupGrub;
  nixosDiskSizeHint = nixosOutputs.diskSizeHint;
  nixosDiskSizeMiB = nixosOutputs.diskSizeMiB;
  nixosDiskoConfiguration = nixosOutputs.diskoConfiguration;
  mkHomeManagerConfig =
    profile:
    home-manager.lib.homeManagerConfiguration {
      pkgs = pkgsForDarwin;
      modules = [
        ../modules/home-manager
        (
          { lib, ... }:
          {
            home.username = lib.mkDefault profile.user.name;
            home.homeDirectory = lib.mkDefault (toString profile.user.home);
          }
        )
      ];
      extraSpecialArgs = mkNdhHomeManagerSpecialArgs {
        inherit
          self
          worktreePath
          profile
          ;
        ndhContext = {
          inherit
            hostProfile
            catalog
            ;
          inventory = inventoryData;
          generationMode = "full";
          vmProvider = hostProfile.vmProvider or "tart";
          nixBashTrampoline = ndhNixBashTrampolineDarwin;
        };
        ndhStore = ndhStoreApiDarwin;
        keysYamlPath = "${toString profile.user.home}/.local/var/run/secrets/sops/ssh-keys.yaml";
      };
    };
  darwinOutputs = mkDarwinOutputs {
    inherit hostProfile catalog;
    inventory = inventoryData;
    profileModule =
      { ... }:
      {
        imports = [
          profileModule
          (
            { ... }:
            {
              # These store paths are what the `nerd-tart-<host>-materialize`
              # staging gesture resolves. They reach the Tart bundle, never the
              # darwin system closure — no activation path consumes the bundle.
              tart.configGenerator.rawImageManifestPath = "${nixosDiskImageBringupSystemdZfs}/manifest.yaml";
              tart.configGenerator.rawImageStorePath = "${nixosDiskImageBringupSystemdZfs}/boot.img";
              tart.configGenerator.vmRunSopsAgeHostShare =
                nixosOutputs.nixosConfigurations."${mainName}-nixos".config.ndh.sopsAgeKeyBootstrap.nixosHostKeyImport.enable;
              tart.configGenerator.vmRunFirstBootAttachDiskManifestPath = null;
              tart.configGenerator.vmRunFirstBootAttachDiskPath = "";
              tart.configGenerator.linuxBuilderGcBeforeBuild = linuxBuilderGcBeforeBuild;
              tart.configGenerator.enableBuildObserve = enableBuildObserve;
              tart.configGenerator.buildObserveInterval = buildObserveInterval;
            }
          )
        ]
        ++ darwinExtraModules;
      };
  };
  darwinConfiguration = darwinOutputs.darwinConfigurations.${mainName};
  tartMaterializerPackage = darwinConfiguration.config.tart.configGenerator.materializerPackage;
  autofsNetMaterializerPackage =
    if
      darwinConfiguration ? config
      && darwinConfiguration.config ? services
      && darwinConfiguration.config.services ? nfsDarwin
      && darwinConfiguration.config.services.nfsDarwin ? autofs
      && darwinConfiguration.config.services.nfsDarwin.autofs ? materializerPackage
    then
      darwinConfiguration.config.services.nfsDarwin.autofs.materializerPackage
    else
      null;
  autofsNetMaterializerProgram =
    if autofsNetMaterializerPackage != null then
      "${autofsNetMaterializerPackage}/bin/nfs-autofs-net-materialize"
    else
      null;
  ndhBootstrapRuntimePackage = mkNdhBootstrapRuntimePackage "aarch64-darwin";
  ndhBootstrapInstallerPackage = mkNdhBringupRuntimeInstaller "aarch64-darwin";
  ndhBootstrapRuntimePackageLinux = mkNdhBootstrapRuntimePackage "aarch64-linux";
  ndhBootstrapInstallerPackageLinux = mkNdhBringupRuntimeInstaller "aarch64-linux";
  ndhPrerequisitesInstallerScriptSource =
    pkgsForDarwin.replaceVars ../modules/.common.d/bringup-runtime.d/prerequisites-install-wrapper.sh
      {
        bash = "${pkgsForDarwin.bash}/bin/bash";
        loggerTag = "ndh.bringup-runtime.prerequisites-install.darwin";
        autofsMaterializerProgram =
          if autofsNetMaterializerProgram != null then autofsNetMaterializerProgram else "";
        standaloneInstaller = "${ndhBootstrapInstallerPackage}/bin/${ndhBringupInstallerCommand}";
      };
  ndhPrerequisitesInstallerScriptSourceLinux =
    pkgsForLinux.replaceVars ../modules/.common.d/bringup-runtime.d/prerequisites-install-wrapper.sh
      {
        bash = "${pkgsForLinux.bash}/bin/bash";
        loggerTag = "ndh.bringup-runtime.prerequisites-install.linux";
        autofsMaterializerProgram = "";
        standaloneInstaller = "${ndhBootstrapInstallerPackageLinux}/bin/${ndhBringupInstallerCommand}";
      };
  ndhPrerequisitesInstallerPackage = pkgsForDarwin.runCommand ndhBringupInstallerAttr { } ''
    install -Dm755 ${ndhPrerequisitesInstallerScriptSource} "$out/bin/${ndhBringupInstallerCommand}"
  '';
  ndhPrerequisitesInstallerPackageLinux = pkgsForLinux.runCommand ndhBringupInstallerAttr { } ''
    install -Dm755 ${ndhPrerequisitesInstallerScriptSourceLinux} "$out/bin/${ndhBringupInstallerCommand}"
  '';
  hostDarwinPackages = {
    ${ndhBringupRuntimeAttr} = ndhBootstrapRuntimePackage;
    ${ndhBringupInstallerAttr} = ndhPrerequisitesInstallerPackage;
    ${ndhVmTartMaterializeAttr} = tartMaterializerPackage;
    ${ndhVmTartBootstrapInstallerAttr} = mkNdhVmTartBootstrapInstallerPackage "aarch64-darwin";
  };
  hostLinuxPackages = {
    ${ndhBringupRuntimeAttr} = ndhBootstrapRuntimePackageLinux;
    ${ndhBringupInstallerAttr} = ndhPrerequisitesInstallerPackageLinux;
  };
  hostDarwinApps = {
    ${ndhBringupInstallerAttr} = {
      type = "app";
      program = "${ndhPrerequisitesInstallerPackage}/bin/${ndhBringupInstallerCommand}";
    };
    ${ndhVmTartMaterializeAttr} = {
      type = "app";
      program = "${tartMaterializerPackage}/bin/${ndhVmTartMaterializeAttr}";
    };
    ${ndhVmTartBootstrapInstallerAttr} = {
      type = "app";
      program = "${(mkNdhVmTartBootstrapInstallerPackage "aarch64-darwin")}/bin/${ndhVmTartBootstrapInstallerAttr}";
    };
  };
  hostLinuxApps = {
    ${ndhBringupInstallerAttr} = {
      type = "app";
      program = "${ndhPrerequisitesInstallerPackageLinux}/bin/${ndhBringupInstallerCommand}";
    };
  };

  # Home Manager configuration for the single host user.
  homeManagerConfigurations = {
    default = mkHomeManagerConfig hostUserProfile;
  };
in
nixosOutputs
// darwinOutputs
// {
  inherit
    darwinConfiguration
    nixosConfiguration
    nixosDiskImage
    nixosDiskImageBringupSystemd
    nixosDiskImageBringupSystemdZfs
    nixosBringupSecretCanaryBuild
    nixosDiskImageBringupGrub
    nixosDiskSizeHint
    homeManagerConfigurations
    ;
  homeManagerConfiguration = homeManagerConfigurations.default;
  diskoConfigurations = {
    "${mainName}-nixos" = nixosDiskoConfiguration;
  };
  pkgs = {
    darwin = pkgsForDarwin;
    linux = pkgsForLinux;
  };

  packages =
    nixpkgs.lib.optionalAttrs (hostDarwinPackages != { }) {
      aarch64-darwin = hostDarwinPackages;
    }
    // nixpkgs.lib.optionalAttrs (hostLinuxPackages != { }) {
      aarch64-linux = hostLinuxPackages;
    };

  apps =
    nixpkgs.lib.optionalAttrs (hostDarwinApps != { }) {
      aarch64-darwin = hostDarwinApps;
    }
    // nixpkgs.lib.optionalAttrs (hostLinuxApps != { }) {
      aarch64-linux = hostLinuxApps;
    };

  defaultPackage."aarch64-darwin" = darwinConfiguration.system;
}
