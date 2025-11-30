{ config, lib, pkgs, ... }:

let
  inherit (lib)
    filterAttrs
    hasInfix
    mapAttrs
    mapAttrsToList
    mkEnableOption
    mkOption
    mkIf
    mkDefault
    optionalAttrs
    types;
  cfg = config.programs.flox;

  defaultProfileCommon = builtins.readFile ./flox-env.profile-common.sh;

  toml = pkgs.formats.toml { };

in
{
  options.programs.flox = {
    enable = mkEnableOption "Declarative flox environment management";

    environmentName = mkOption {
      type = types.str;
      default = "home";
      description = "Name of the flox environment";
    };

    packages = mkOption {
      type = types.listOf (types.submodule {
        options = {
          name = mkOption {
            type = types.str;
            description = "Package install name";
          };
          pkg-path = mkOption {
            type = types.str;
            description = "Nixpkgs attribute path";
          };
          systems = mkOption {
            type = types.nullOr (types.listOf types.str);
            default = null;
            description = "Supported systems (optional)";
          };
          version = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Optional version constraint";
          };
          pkg-group = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Optional flox package group";
          };
        };
      });
      default = [];
      description = "List of packages to install in the flox environment";
    };

    vars = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = "Environment variables injected through the Flox manifest";
    };

    hook = mkOption {
      type = types.nullOr types.lines;
      default = null;
      description = "Hook script (manifest [hook.on-activate])";
    };

    profile = mkOption {
      type = types.attrsOf types.lines;
      default = { common = defaultProfileCommon; };
      description = "Shell profile fragments sourced by Flox during activation";
    };

    includeEnvironments = mkOption {
      type = types.listOf (types.submodule {
        options = {
          dir = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Path to another flox environment to include";
          };
          remote = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Remote owner/name reference";
          };
          trust = mkOption {
            type = types.bool;
            default = false;
            description = "Whether to trust the remote include";
          };
        };
      });
      default = [];
      description = "List of Flox environments to compose via manifest [include]";
    };

    supportedSystems = mkOption {
      type = types.listOf types.str;
      default = [ "aarch64-darwin" "aarch64-linux" ];
      description = "Supported systems for the flox environment";
    };

    envDir = mkOption {
      type = types.str;
      default = null;
      description = "Directory where the flox environment should be created";
    };

    manifestPath = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Generated Flox manifest path (stored in the Nix store)";
    };

    writeManifest = mkOption {
      type = types.bool;
      default = true;
      description = ''
        If enabled, the Home Manager module installs the generated manifest 
        in the <envDir>/.flox/env/manifest.toml path.
      '';
    };

    manifestAttrs = mkOption {
      type = types.attrs;
      default = { };
      description = "Structured representation of the Flox manifest";
    };

    packageNames = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "List of package names managed by Flox";
    };
  };

  config = mkIf cfg.enable (
    let
      installEntries = builtins.listToAttrs (map (pkg: {
        name = pkg.name;
        value = filterAttrs (_: v: v != null) (builtins.removeAttrs pkg [ "name" ]);
      }) cfg.packages);

      includeEnvs = map (entry: filterAttrs (_: v: v != null) entry) cfg.includeEnvironments;

      placeholderFor = name: "__FLOX_PROFILE_" + name + "__";

      multilineProfileEntries = filterAttrs (_: value: hasInfix "\n" value) cfg.profile;

      profileForToml =
        if multilineProfileEntries == { } then cfg.profile else
        mapAttrs (name: value: if hasInfix "\n" value then placeholderFor name else value) cfg.profile;

      profileReplacements =
        mapAttrsToList (name: value: {
          placeholder = placeholderFor name;
          content = value;
        }) multilineProfileEntries;

      manifestBase = {
        version = 1;
        install = installEntries;
        options.systems = cfg.supportedSystems;
      };

      manifestWithVars = manifestBase // optionalAttrs (cfg.vars != { }) { vars = cfg.vars; };

      manifestWithProfile = profileAttr:
        manifestWithVars // optionalAttrs (profileAttr != { }) { profile = profileAttr; };

      manifestWithHook = profileAttr:
        manifestWithProfile profileAttr // optionalAttrs (cfg.hook != null) {
        hook.on-activate = cfg.hook;
      };

      manifestWithInclude = profileAttr:
        manifestWithHook profileAttr // optionalAttrs (includeEnvs != []) {
          include.environments = includeEnvs;
        };

      manifest = manifestWithInclude cfg.profile;

      manifestForToml = manifestWithInclude profileForToml;

      rawManifestFile = toml.generate "flox-manifest.toml" manifestForToml;

      manifestPath =
        if profileReplacements == [ ] then rawManifestFile else
        let
          replacementsJson = builtins.toJSON profileReplacements;
        in
          pkgs.runCommand "flox-manifest.toml" { } ''
          set -exuo pipefail
          cp ${rawManifestFile} $out
          chmod u+w $out
          cat <<'EoF' > replacements.json
          ${replacementsJson}
          EoF
          ${pkgs.python3Minimal}/bin/python ${./flox-manifest-replace.py} replacements.json "$out"
        '';

      shouldInstallManifest =
        cfg.writeManifest && cfg.envDir != null && manifestPath != null;
    in {
      programs.flox = {
        inherit manifestPath;
        manifestAttrs = manifest;
        packageNames = map (pkg: pkg.name) cfg.packages;
      };

      home-manager.sharedModules = lib.mkIf shouldInstallManifest [
        ({ lib, ... }: {
          home.activation.floxInstallManifest =
            lib.hm.dag.entryAfter [ "writeBoundary" ] ''
              env_dir=${lib.escapeShellArg cfg.envDir}
              flox_dir="$env_dir/.flox"
              target_manifest="$flox_dir/env/manifest.toml"
              if [ ! -d "$flox_dir" ]; then
                ${pkgs.flox}/bin/flox init --dir "$env_dir"
              fi
              if [ ! -f "$target_manifest" ] || ! cmp -s ${lib.escapeShellArg manifestPath} "$target_manifest"; then
                install -D ${lib.escapeShellArg manifestPath} "$target_manifest"
              fi
            '';
        })
      ];
    }
  );
}
