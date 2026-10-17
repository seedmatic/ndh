{
  config,
  lib,
  pkgs,
  ...
}:
# A builder's nix signing key, derived from its own host key (roles × keys B2): one declaration for NixOS guests
# and operator seats; the platform modules run ndh.nixSigning.placeScript before nix-daemon signs.
#
# Every machine trusts every recorded nixSigning (keys.yaml, current slots only). A machine signs with its own
# once it serves its own host key AND keys.yaml records its public; until then it keeps the fleet key, which
# stays beside it during the transition.
let
  cfg = config.ndh.nixSigning;
  machine = config.networking.hostName;
  hostEntry = config.ndh.keysYaml.keys."host-${machine}" or { };
  slots = hostEntry.slots or { };
  newest =
    if slots == { } then null else slots.${lib.last (lib.sort lib.lessThan (lib.attrNames slots))};
  recorded = if newest == null then null else newest.nixSigning or null;
  name = if recorded == null then null else lib.head (lib.splitString ":" recorded);
  version = if name == null then null else lib.last (lib.splitString "-" name);
  derive = pkgs.callPackage ../../packages/ndh-nix-signing-derive { };
in
{
  options.ndh.nixSigning = {
    signs = lib.mkOption {
      type = lib.types.bool;
      readOnly = true;
      default = config.ndh.hostKey.own && recorded != null;
      description = "Whether this machine signs with its own derived key: it serves its own host key, and keys.yaml records the public.";
    };
    dir = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = "/var/lib/ndh/nix-signing";
      description = "Where the derived secret is placed, root 0700, outside the store.";
    };
    placeScript = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      description = "Derives the key from ndh.hostKey.file, checks it against keys.yaml, and places it atomically.";
    };
  };

  config = lib.mkMerge [
    {
      nix.settings.extra-trusted-public-keys = import ./nix-signing.d/trust.nix {
        inherit lib;
      } config.ndh.keysYaml.keys;
    }
    (lib.mkIf cfg.signs {
      ndh.nixSigning.placeScript = pkgs.writeShellApplication {
        name = "ndh-nix-signing-key";
        runtimeInputs = [ pkgs.coreutils ];
        text = ''
          derive=${derive}/bin/ndh-nix-signing-derive
          hostKeyFile=${lib.escapeShellArg config.ndh.hostKey.file}
          name=${lib.escapeShellArg name}
          label=${lib.escapeShellArg "seedmatic/nix-signing/${version}"}
          recorded=${lib.escapeShellArg recorded}
          dir=${lib.escapeShellArg cfg.dir}
        ''
        + builtins.readFile ./nix-signing.d/place.sh;
      };
      nix.settings.secret-key-files = [ "${cfg.dir}/${name}.sec" ];
    })
  ];
}
