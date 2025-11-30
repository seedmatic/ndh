{ config, lib, pkgs, ... }:

let
  inherit (lib)
    mkEnableOption
    mkOption
    mkIf
    types;
  cfg = config.programs.flox;

in
{
  options.programs.flox = {
    enable = mkEnableOption "Declarative flox environment management";

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


    pullRemotes = mkOption {
      type = types.listOf (types.submodule {
        options = {
          name = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Friendly handle for the pulled environment (defaults to remote)";
          };
          remote = mkOption {
            type = types.str;
            description = "FloxHub owner/name identifier to pull";
          };
          dir = mkOption {
            type = types.str;
            description = "Directory where the Flox environment should reside";
          };
          ensureDir = mkOption {
            type = types.bool;
            default = true;
            description = "Create the directory when it is missing";
          };
          skipIfMissing = mkOption {
            type = types.bool;
            default = false;
            description = "Skip pulling when the directory does not exist";
          };
          force = mkOption {
            type = types.bool;
            default = false;
            description = "Pass --force to flox pull";
          };
          copy = mkOption {
            type = types.bool;
            default = false;
            description = "Pass --copy to flox pull";
          };
          initName = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Override the flox init --name argument";
          };
        };
      });
      default = [];
      description = "Remote Flox environments that should be pulled into specific directories";
    };

    packageNames = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "List of package names managed by Flox";
    };
  };

  config = mkIf cfg.enable (
    let
      pullScripts = map (entry:
        let
          envDir = lib.escapeShellArg entry.dir;
          remote = lib.escapeShellArg entry.remote;
          initName = if entry.initName != null then entry.initName else entry.name;
          initArg = if initName != null then " --name ${lib.escapeShellArg initName}" else "";
          ensureDir = if entry.ensureDir then "1" else "0";
          skipMissing = if entry.skipIfMissing then "1" else "0";
          forceSnippet = if entry.force then ''
            pull_opts="$pull_opts --force"
          '' else "";
          copySnippet = if entry.copy then ''
            pull_opts="$pull_opts --copy"
          '' else "";
        in ''
          env_dir=${envDir}
          remote=${remote}
          ensure_dir=${ensureDir}
          skip_missing=${skipMissing}
          if [ ! -d "$env_dir" ]; then
            if [ "$ensure_dir" = "1" ]; then
              mkdir -p "$env_dir"
            elif [ "$skip_missing" = "1" ]; then
              echo "flox: skip pulling ${entry.remote} (missing $env_dir)" >&2
            else
              echo "flox: directory $env_dir is missing (cannot pull ${entry.remote})" >&2
            fi
          fi
          if [ -d "$env_dir" ]; then
            if [ ! -d "$env_dir/.flox" ]; then
              ${pkgs.flox}/bin/flox init --dir "$env_dir"${initArg}
            fi
            pull_opts=""
            ${forceSnippet}
            ${copySnippet}
            if ! ${pkgs.flox}/bin/flox pull --dir "$env_dir"$pull_opts ${remote}; then
              echo "flox: warning: pull ${entry.remote} into $env_dir failed" >&2
            fi
          fi
        '') cfg.pullRemotes;

      pullModule = {
        home.activation.floxPullRemotes =
          lib.hm.dag.entryAfter [ "writeBoundary" ] (lib.concatStringsSep "\n" pullScripts);
      };
    in {
      programs.flox.packageNames = map (pkg: pkg.name) cfg.packages;

      home-manager.sharedModules =
        lib.optionals (cfg.pullRemotes != [ ]) [ pullModule ];
    }
  );
}
