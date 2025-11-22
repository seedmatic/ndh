{ config, lib, pkgs, ... }:

let
  inherit (lib)
    filterAttrs
    mkEnableOption
    mkOption
    mkIf
    optionalAttrs
    types;
  cfg = config.programs.floxEnv;
  dollar = "$";

  defaultProfileCommon = ''
    flox_env_local="${dollar}{FLOX_ENV_PROJECT}/.local"

    mkdir -p \
      "${dollar}{flox_env_local}/.config" \
      "${dollar}{flox_env_local}/.cache" \
      "${dollar}{flox_env_local}/.local/share" \
      "${dollar}{flox_env_local}/.local/state" \
      "${dollar}{flox_env_local}/.local/xdg"

    export XDG_CONFIG_HOME="${dollar}{XDG_CONFIG_HOME:-${dollar}{flox_env_local}/.config}"
    export XDG_CACHE_HOME="${dollar}{XDG_CACHE_HOME:-${dollar}{flox_env_local}/.cache}"
    export XDG_DATA_HOME="${dollar}{XDG_DATA_HOME:-${dollar}{flox_env_local}/.local/share}"
    export XDG_STATE_HOME="${dollar}{XDG_STATE_HOME:-${dollar}{flox_env_local}/.local/state}"
    export XDG_RUNTIME_DIR="${dollar}{XDG_RUNTIME_DIR:-${dollar}{flox_env_local}/.local/xdg}"

    if [ -d "${dollar}{FLOX_ENV_PROJECT}/.github" ] && command -v gh >/dev/null 2>&1; then
      gh_login=""
      if [ -n "${dollar}{GH_TOKEN:-}" ]; then
        gh_login=$(gh api user --jq '.login' 2>/dev/null || true)
      elif command -v pass >/dev/null 2>&1; then
        gh_secret=$(pass show coding/github@work 2>/dev/null | head -n1 || true)
        if [ -n "${dollar}{gh_secret}" ]; then
          gh_login=$(env GH_TOKEN="${dollar}{gh_secret}" gh api user --jq '.login' 2>/dev/null || true)
        fi
      fi

      if [ -n "${dollar}{gh_login}" ]; then
        remote=$(git -C "${dollar}{FLOX_ENV_PROJECT}" remote get-url origin 2>/dev/null || true)
        if [ -n "${dollar}{remote}" ]; then
          owner=$(printf '%s' "${dollar}{remote}" | cut -d'/' -f4)
          repo_name=$(printf '%s' "${dollar}{remote}" | cut -d'/' -f5 | cut -d'.' -f1)
          export GITHUB_LOGIN="${dollar}{gh_login}"
          export GITHUB_OWNER="${dollar}{owner}"
          export GITHUB_REPOSITORY="${dollar}{owner}/${dollar}{repo_name}"
        fi
      fi
    fi

    mvnw_path="${dollar}{FLOX_ENV_PROJECT}/mvnw"
    if [ -x "${dollar}{mvnw_path}" ]; then
      maven_user_config="${dollar}{FLOX_ENV_PROJECT}/.m2"
      mkdir -p "${dollar}{maven_user_config}"
      export MAVEN_USER_CONFIG="${dollar}{maven_user_config}"
      export MAVEN_SETTINGS="${dollar}{MAVEN_USER_CONFIG}/settings.xml"

      if [ -n "${dollar}{MAVEN_ARGS:-}" ]; then
        case " ${dollar}{MAVEN_ARGS} " in
          *"--settings="*) ;;
          *) export MAVEN_ARGS="${dollar}{MAVEN_ARGS} --settings=${dollar}{MAVEN_SETTINGS}" ;;
        esac
      else
        export MAVEN_ARGS="--settings=${dollar}{MAVEN_SETTINGS}"
      fi

      if [ -d "${dollar}{FLOX_ENV_PROJECT}/.mvnrepository" ]; then
        export MAVEN_LOCAL_REPOSITORY="${dollar}{FLOX_ENV_PROJECT}/.mvnrepository"
      elif [ -d "${dollar}{FLOX_ENV_PROJECT}/.m2/repo" ]; then
        export MAVEN_LOCAL_REPOSITORY="${dollar}{FLOX_ENV_PROJECT}/.m2/repo"
      fi

      maven_version_output=$("${dollar}{mvnw_path}" -N -q -DmavenVersion=3.9.9 \
        -Dexpression=maven.version -Doutput=/dev/stdout help:evaluate 2>/dev/null | grep -v '^\[.*\]' | tail -n1)
      if [ -n "${dollar}{maven_version_output}" ]; then
        export MAVEN_VERSION="${dollar}{maven_version_output}"
      fi
    fi
  '';

  # Use a safe default path that works in both Darwin and Home Manager contexts
  defaultProjectRoot =
    if config ? home && config.home ? homeDirectory
    then "${config.home.homeDirectory}/Gits/nxmatic/nix-darwin-home"
    else "${config.profile.user.home}/Gits/nxmatic/nix-darwin-home";  # use profile-provided user home

  toml = pkgs.formats.toml { };
in
{
  options.programs.floxEnv = {
    enable = mkEnableOption "Declarative flox environment management";

    environmentName = mkOption {
      type = types.str;
      default = "nix-darwin-home";
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
      default = [ "aarch64-darwin" "aarch64-linux" "x86_64-darwin" "x86_64-linux" ];
      description = "Supported systems for the flox environment";
    };

    projectRoot = mkOption {
      type = types.str;
      default = defaultProjectRoot;
      description = "Root directory where the flox environment should be created";
    };

    manifestFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Generated Flox manifest path";
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

  config = mkIf cfg.enable {
    programs.floxEnv = let
      installEntries = builtins.listToAttrs (map (pkg: {
        name = pkg.name;
        value = filterAttrs (_: v: v != null) (builtins.removeAttrs pkg [ "name" ]);
      }) cfg.packages);

      includeEnvs = map (entry: filterAttrs (_: v: v != null) entry) cfg.includeEnvironments;

      manifestBase = {
        version = 1;
        install = installEntries;
        options.systems = cfg.supportedSystems;
      };

      manifestWithVars = manifestBase // optionalAttrs (cfg.vars != { }) { vars = cfg.vars; };

      manifestWithProfile = manifestWithVars // optionalAttrs (cfg.profile != { }) { profile = cfg.profile; };

      manifestWithHook = manifestWithProfile // optionalAttrs (cfg.hook != null) {
        hook.on-activate = cfg.hook;
      };

      manifestWithInclude = manifestWithHook // optionalAttrs (includeEnvs != []) {
        include.environments = includeEnvs;
      };

      manifest = manifestWithInclude;
    in {
      manifestFile = toml.generate "flox-manifest.toml" manifest;
      manifestAttrs = manifest;
      packageNames = map (pkg: pkg.name) cfg.packages;
    };
  };
}
