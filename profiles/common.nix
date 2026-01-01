{ config, home-manager, pkgs, lib, ... }:

let
  inherit (pkgs) stdenv;
  inherit (lib) mkIf;
  cfg = config.profile;
  defaultUserHome =
    if stdenv.isDarwin then "Users" else "${config.users.defaultUserHome}";

  # Shared user profile mapping (@codebase)
  # This defines the mapping between different profiles and their corresponding usernames
  # Used by both profile configurations and symlink modules
  userMapping = {
    # Profile name -> user configuration mapping
    profileUsers = {
      work = {
        name = "stephane.lacoin";
        description = "Stephane Lacoin (aka nxmatic)";
        email = "stephane.lacoin@hyland.com";
      };

      committed = {
        name = "nxmatic";
        description = "Stephane Lacoin (aka nxmatic)";
        email = "stephane.lacoin@gmail.com";
      };
    };
  };

  # Shared host catalog (@codebase)
  # Consolidated facts about managed hosts and their builder endpoints.
  # Hosts are macOS (baremetal or VM); builders can be darwin or Linux/NixOS VMs.
  hostsCatalog = {
    bioskop = [
      {
        platform = "darwin";
        form = "baremetal";
        builder = {
          hostName = "bioskop-darwin";
          systems = [ "aarch64-darwin" ];
          maxJobs = 8;
          protocol = "ssh-ng";
        };
      }
      {
        platform = "darwin";
        form = "baremetal";
        vm = { kind = "qemu"; manager = "nix-darwin"; };
        builder = {
          hostName = "bioskop-linux";
          systems = [ "aarch64-linux" ];
          maxJobs = 8;
          protocol = "ssh-ng";
        };
      }
      {
        platform = "darwin";
        form = "baremetal";
        vm = { kind = "vz"; manager = "lima"; };
        builder = {
          hostName = "bioskop-nixos";
          systems = [ "aarch64-linux" ];
          maxJobs = 8;
          protocol = "ssh-ng";
        };
      }
    ];

    alcide = [
      # alcide runs as a Tart/VZ macOS VM and does NOT serve as a darwin builder itself; it offloads to remote builders
      {
        platform = "darwin";
        form = "vm";
        vm = { kind = "vz"; manager = "tart"; };
        builder = null;
      }
      {
        platform = "darwin";
        form = "vm";
        vm = { kind = "vz"; manager = "lima"; };
        builder = {
          hostName = "alcide-nixos";
          systems = [ "aarch64-linux" ];
          maxJobs = 8;
          protocol = "ssh-ng";
        };
      }
    ];
  };
in {
  options = {
    profile = lib.mkOption {
      description = "Profile currently evaluated";
      type = lib.types.submodule {
        options = {
          name = lib.mkOption {
            type = lib.types.str;
            description = "The name of the profile";
            default = "jdoe";
          };
          email = lib.mkOption {
            type = lib.types.str;
            description = "The email of the user";
            # Keep a simple static default; we derive a dynamic one later in config (@codebase)
            default = lib.mkDefault "user@example.com";
          };
          homeSymlinks = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            description =
              "List of alternative usernames to create symlinks for in /home";
            default = [ ];
            example = [ "nxmatic" ];
          };
          darwin = lib.mkOption {
            type = lib.types.submodule {
              options = {
                knownNetworkServices = lib.mkOption {
                  type = lib.types.listOf lib.types.str;
                  description = "List of known network services";
                  default =
                    [ "Wi-Fi" "Ethernet Adaptor" "Thunderbolt Ethernet" ];
                };
              };
            };
          };
          host = lib.mkOption {
            type = lib.types.submodule {
              options = {
                hostName = lib.mkOption {
                  type = lib.types.str;
                  description = "The name of the host";
                  default = "nameless-host";
                };
                hostAlias = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  description = "Optional alias for the host (null means none).";
                  example = "my-mac";
                };
                forceRemoteBuilds = lib.mkOption {
                  type = lib.types.bool;
                  description = "Force this host to offload builds to remote builders (set max-jobs = 0 and configure remote builders).";
                  default = false;
                  example = true;
                };
                preferredBuilderHosts = lib.mkOption {
                  type = lib.types.listOf lib.types.str;
                  default = [ ];
                  example = [ "bioskop" "alcide" ];
                  description = "Host keys from hostsCatalog to pull builder endpoints from (e.g., include bioskop so alcide offloads to bioskop's builders). If empty, defaults to the current host only.";
                };
                remoteBuilders = lib.mkOption {
                  type = lib.types.listOf lib.types.attrs;
                  default = [ ];
                  example = [
                    # Example: bioskop (darwin host) exporting its darwin builder and linux-builder VM
                    { hostName = "bioskop-darwin"; systems = [ "aarch64-darwin" ]; maxJobs = 4; protocol = "ssh-ng"; }
                    { hostName = "bioskop-linux"; systems = [ "aarch64-linux" ]; maxJobs = 8; protocol = "ssh-ng"; supportedFeatures = [ "kvm" "big-parallel" ]; }
                    # Example: alcide (macbook-pro) exporting its darwin builder and nixos VM
                    { hostName = "alcide-darwin"; systems = [ "aarch64-darwin" ]; maxJobs = 2; protocol = "ssh-ng"; }
                    { hostName = "alcide-nixos"; systems = [ "aarch64-linux" ]; maxJobs = 4; protocol = "ssh-ng"; }
                  ];
                  description = "BuildMachines entries for the managed hosts (Darwin builders and their Linux/NixOS VMs). Leave empty to disable remote build enforcement on this host.";
                };
                builderCatalog = lib.mkOption {
                  type = lib.types.listOf lib.types.attrs;
                  default = [ ];
                  example = [
                    {
                      host = "bioskop";
                      platform = "darwin";  # macOS host
                      form = "baremetal";    # bare metal vs vm
                      builder = {
                        hostName = "bioskop-darwin";
                        systems = [ "aarch64-darwin" ];
                        maxJobs = 8;
                        protocol = "ssh-ng";
                      };
                    }
                    {
                      host = "bioskop";
                      platform = "darwin";
                      form = "baremetal";
                      vm = { kind = "qemu"; manager = "nix-darwin"; };
                      builder = {
                        hostName = "bioskop-linux";
                        systems = [ "aarch64-linux" ];
                        maxJobs = 8;
                        protocol = "ssh-ng";
                      };
                    }
                    {
                      host = "bioskop";
                      platform = "darwin";
                      form = "baremetal";
                      vm = { kind = "vz"; manager = "lima"; };
                      builder = {
                        hostName = "bioskop-nixos";
                        systems = [ "aarch64-linux" ];
                        maxJobs = 8;
                        protocol = "ssh-ng";
                      };
                    }
                    {
                      host = "alcide";
                      platform = "darwin";  # running under tart/vz
                      form = "vm";
                      vm = { kind = "vz"; manager = "tart"; };
                      builder = {
                        hostName = "alcide-darwin";
                        systems = [ "aarch64-darwin" ];
                        maxJobs = 8;
                        protocol = "ssh-ng";
                      };
                    }
                    {
                      host = "alcide";
                      platform = "darwin";
                      form = "vm";
                      vm = { kind = "vz"; manager = "lima"; };
                      builder = {
                        hostName = "alcide-nixos";
                        systems = [ "aarch64-linux" ];
                        maxJobs = 8;
                        protocol = "ssh-ng";
                      };
                    }
                  ];
                  description = "Catalog of managed hosts and their builder endpoints with physical characteristics (platform/form) and VM details (kind/manager). When set and remoteBuilders is empty, the distributed-builds module will use this catalog; features are derived automatically.";
                };
                tailnet = lib.mkOption {
                  type = lib.types.submodule {
                    options = {
                      name = lib.mkOption {
                        type = lib.types.str;
                        description = "The name of the tailnet";
                        default = "mammoth-skate";
                      };
                      domain = lib.mkOption {
                        type = lib.types.str;
                        description = "The domain of the tailnet";
                        default = "ts.net";
                      };
                    };
                  };
                };
              };
            };
          };

          user = lib.mkOption {
            type = lib.types.submodule {
              options = {
                name = lib.mkOption {
                  type = lib.types.str;
                  description = "The name of the user";
                  default = "jdoe";
                };
                description = lib.mkOption {
                  type = lib.types.str;
                  description = "The description of the user";
                  # Simple default; dynamic form applied later (@codebase)
                  default = lib.mkDefault "Default user";
                };
                shell = lib.mkOption {
                  type = lib.types.package;
                  description = "The shell of the user";
                  default = pkgs.bash;
                  example = "bash";
                };
                uid = lib.mkOption {
                  type = lib.types.nullOr lib.types.int;
                  default = null;
                  description =
                    "Optional fixed UID to align with host (e.g. macOS UID 501/503).";
                };
                gid = lib.mkOption {
                  type = lib.types.nullOr lib.types.int;
                  default = null;
                  description =
                    "Optional fixed primary GID. Defaults to uid if set and gid is null.";
                };
                isNormalUser = lib.mkOption {
                  type = lib.types.bool;
                  description = "Whether the user is a normal user";
                  default = true;
                };
                isSystemUser = lib.mkOption {
                  type = lib.types.bool;
                  description = "Whether the user is a system user";
                  default = false;
                };
                group = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  description =
                    "Optional primary group name; if null a group matching the username should be created elsewhere";
                  default = null;
                };
                home = lib.mkOption {
                  type = lib.types.path;
                  description = "The home directory of the user";
                  # Static placeholder; dynamic path set in config phase (@codebase)
                  default = builtins.toPath "/${defaultUserHome}/jdoe";
                };
                homeMode = lib.mkOption {
                  type = lib.types.str;
                  description = "The home directory permissions";
                  default = "0755";
                };
              };
            };
          };
        };
      };
    };
  };

  # Compose config: expose userMapping. Avoid self-reference causing recursion
  config = {
    _module.args.userMapping =
      userMapping; # (@codebase) keep simple to avoid recursion
    _module.args.hostsCatalog = hostsCatalog; # (@codebase) expose consolidated host facts
    # Dynamic defaults (@codebase): adjust user home path to use the resolved user name
    # instead of the static placeholder jdoe so Home Manager's activation check matches $HOME.
    profile.user.home = lib.mkDefault (builtins.toPath "/${defaultUserHome}/${config.profile.user.name}");

    # Default builder catalog from shared hostsCatalog based on preferredBuilderHosts (fallback: current host only)
    profile.host.preferredBuilderHosts = lib.mkDefault [ config.profile.host.hostName ];

    profile.host.builderCatalog = lib.mkDefault (
      let
        wanted = config.profile.host.preferredBuilderHosts;
        addDefaultFeatures = entry:
          let
            base = entry.builder;
            baseFeatures = base.supportedFeatures or [ ];
            vmKind = if entry ? vm then (entry.vm.kind or null) else null;
            maxJobs = base.maxJobs or 0;
            defaults =
              lib.optional (maxJobs >= 8) "big-parallel"
              ++ lib.optional (vmKind == "qemu") "kvm";
          in entry // {
            builder = base // { supportedFeatures = lib.unique (baseFeatures ++ defaults); };
          };
        entriesFor = host:
          if builtins.hasAttr host hostsCatalog then map addDefaultFeatures hostsCatalog.${host} else [ ];
      in lib.concatMap entriesFor wanted
    );
  };
}
