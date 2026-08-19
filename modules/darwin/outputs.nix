{
  inputs,
  pkgsForDarwin,
  ndhStoreApiDarwin,
  ndhNixBashTrampolineDarwin,
  mkModulesFor,
  mkSpecialArgs,
}:
let
  ndhNixBashTrampoline = ndhNixBashTrampolineDarwin;

  hostMainNameForProfile =
    hostProfile:
    if (hostProfile ? hostAlias && hostProfile.hostAlias != null && hostProfile.hostAlias != "") then
      hostProfile.hostAlias
    else
      hostProfile.hostName;

  mkDarwinConfig =
    {
      hostProfile,
      profileModule,
      catalog,
      inventory,
      extraModules ? [ ],
    }:
    let
      preModules = [
        profileModule
      ]
      ++ extraModules;
      modules = mkModulesFor {
        inherit hostProfile preModules;
        system = "darwin";
      };
      specialArgs = mkSpecialArgs {
        inherit modules;
        system = "aarch64-darwin";
        extraArgs = {
          inherit
            hostProfile
            catalog
            inventory
            ;
          ndh = {
            context = {
              inherit
                hostProfile
                catalog
                inventory
                ;
              generationMode = "full";
              vmProvider = hostProfile.vmProvider or "tart";
              nixBashTrampoline = ndhNixBashTrampoline;
            };
            store = ndhStoreApiDarwin;
          };
          claude-hub = inputs.claude-hub;
        };
      };
    in
    inputs.darwin.lib.darwinSystem {
      inherit specialArgs modules;
      system = "aarch64-darwin";
      pkgs = pkgsForDarwin.extend (
        final: prev: {
          chromium-bin = inputs.chromium-bin.packages."aarch64-darwin".default;
        }
      );
    };

  mkDarwinOutputs =
    {
      hostProfile,
      profileModule,
      catalog,
      inventory,
      ...
    }:
    let
      mainName = hostMainNameForProfile hostProfile;

      mkDarwinVmVariant =
        vmProvider:
        mkDarwinConfig {
          hostProfile = hostProfile // {
            inherit vmProvider;
          };
          inherit profileModule catalog inventory;
        };

      darwinConfiguration = mkDarwinVmVariant (hostProfile.vmProvider or "tart");
      darwinConfigurationTart = mkDarwinVmVariant "tart";
      darwinConfigurations = {
        "${hostProfile.hostName}" = darwinConfiguration;
        "${mainName}-tart" = darwinConfigurationTart;
      }
      // (
        if (hostProfile ? hostAlias && hostProfile.hostAlias != null && hostProfile.hostAlias != "") then
          {
            "${hostProfile.hostAlias}" = darwinConfiguration;
          }
        else
          { }
      );
    in
    {
      inherit darwinConfigurations;
    };
in
{
  inherit mkDarwinConfig mkDarwinOutputs;
}
