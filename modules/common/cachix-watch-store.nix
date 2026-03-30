# Shared options for nxmatic Cachix watch-store across Darwin and NixOS (@codebase)
{
  config,
  lib,
  ...
}:
let
  cfg = config.services.nxmaticCachixWatchStore;
in
{
  options.services.nxmaticCachixWatchStore = {
    enable = lib.mkEnableOption "nxmatic Cachix watch-store agent";

    cacheName = lib.mkOption {
      type = lib.types.str;
      default = "nxmatic";
      description = "Cachix cache name to push local store paths to.";
    };

    sopsEncryptedTokenFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        Path to the SOPS-encrypted .secrets YAML file containing
        .cachix.<name>.token.
      '';
    };

    jobs = lib.mkOption {
      type = lib.types.nullOr lib.types.int;
      default = 4;
      description = "Optional worker count for cachix watch-store pushes.";
    };

    compressionLevel = lib.mkOption {
      type = lib.types.nullOr (lib.types.ints.between 0 16);
      default = null;
      description = "Optional zstd compression level for Cachix uploads.";
    };

    signingKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional signing key file for self-managed binary cache signing.";
    };

    verbose = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable verbose cachix-watch-store logging.";
    };
  };
}
