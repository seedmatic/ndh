# Path registry for static repo files used as runtime data by NixOS/Darwin
# modules.  Each value is a Nix path literal — `nix` evaluates it to a store
# path whose hash depends ONLY on the file (or directory subtree) imported,
# never on the rest of the worktree.
#
# Why not use `${self}/<file>`?  `self` is a flake input whose hash captures
# the whole git tree, so any unrelated edit (a README typo, a comment in
# `flake.nix`) re-hashes every `"${self}/foo"` reference and forces the
# downstream NixOS module — and thus the bringup disk image — to rebuild.
# Path literals here narrow that input footprint per file.
#
# When you reach for a new "${self}/path" in a module, add it here instead
# and consume `paths.<name>` via the module's argument list.  See
# docs/bringup-image-unification.adoc for the broader byte-stability rationale.
#
# Naming convention: `<area><Subject>` in lowerCamelCase.  Directories use a
# `Dir` suffix only when the module signals intent ("look up siblings inside
# this tree"); a path literal that points at a directory still works as the
# `${...}/<file>` base for a single subfile if the consumer prefers that
# shape.
{
  # Repo-root files
  repoProfile = ./profile.nix;
  repoSecrets = ./.secrets;

  # catalog/
  catalogCacheTrust = ./catalog/cache-trust.nix;
  catalogCacheTrustYaml = ./catalog/cache-trust.yaml;
  catalogLanIgnoredReservations = ./catalog/lan-ignored-reservations.yaml;

  # modules/.common.d/
  modulesCommonDir = ./modules/.common.d;
  modulesCommonCacheTrust = ./modules/.common.d/cache-trust.nix;
  modulesCommonDnsServers = ./modules/.common.d/dns-servers.nix;
  modulesCommonEtcBackupLib = ./modules/.common.d/etc-backup-lib.nix;
  modulesCommonHeadscaleClientWiring = ./modules/.common.d/headscale-client-wiring.nix;
  modulesCommonKeysYaml = ./modules/.common.d/keys-yaml.nix;
  modulesCommonNfsShared = ./modules/.common.d/nfs-shared.nix;
  modulesCommonNixSettings = ./modules/.common.d/nix-settings.nix;
  modulesCommonNixStoreIdentity = ./modules/.common.d/nix-store-identity.nix;
  modulesCommonNixpkgsConfig = ./modules/.common.d/nixpkgs-config.nix;
  modulesCommonOpensshPolicy = ./modules/.common.d/openssh-policy.nix;
  modulesCommonSops = ./modules/.common.d/sops.nix;
  modulesCommonSshPaths = ./modules/.common.d/ssh-paths.nix;
  modulesCommonTailnet = ./modules/.common.d/tailnet.nix;
  modulesCommonVectorConfig = ./modules/.common.d/vector-config.nix;
  modulesCommonNixBashTrampoline = ./modules/.common.d/shell.d/nix-bash-trampoline.sh;
  modulesCommonSshDir = ./modules/.common.d/ssh;
  modulesCommonSshKeysDir = ./modules/.common.d/ssh-keys.d;

  # modules/home-manager/
  modulesHomeManagerDir = ./modules/home-manager;
  modulesHomeManagerSshKeys = ./modules/home-manager/ssh-keys.nix;
  modulesHomeManagerSshKeysYaml = ./modules/home-manager/ssh.d/keys.yaml;
  modulesHomeManagerSshKeyDir = ./modules/home-manager/ssh-key.d;

  # modules/nixos/
  modulesNixosNetworkingMammothSkate = ./modules/nixos/networking-mammoth-skate.nix;
  modulesNixosZfsPoolDiskMap = ./modules/nixos/zfs-pool-disk-map.nix;

  # modules/darwin/
  modulesDarwinHeadscaleToolsDir = ./modules/darwin/headscale-tools;
}
