{
  config,
  lib,
  pkgs,
  ...
}:
# Flox's user config, ~/.config/flox/flox.toml, set key by key at activation (flox-config.d/flox-config.sh): the
# file also holds the operator's hand-kept keys (auto_activate_environments), so it is never replaced.
#
# auth_notifications = false: we use no FloxHub account, and flox printed "You are not logged in to FloxHub" in
# every shell. floxhub_token_storage goes: no FloxHub token is kept anywhere any more.
let
  floxConfig = import ./flox-config.d/package.nix { inherit pkgs; };
  file = "${config.xdg.configHome}/flox/flox.toml";
  cfg = config.ndh.floxConfig;
  # A TOML value: JSON's spelling of a bool, an integer and a basic string is TOML's.
  args = lib.concatLists (
    lib.mapAttrsToList (k: v: [
      "--set"
      k
      (builtins.toJSON v)
    ]) cfg.set
    ++ map (k: [
      "--delete"
      k
    ]) cfg.delete
  );
in
{
  options.ndh.floxConfig = {
    set = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.oneOf [
          lib.types.bool
          lib.types.int
          lib.types.str
        ]
      );
      default = {
        auth_notifications = false;
      };
      description = "Keys of ~/.config/flox/flox.toml set at activation; every other key stays as it is.";
    };
    delete = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "floxhub_token_storage" ];
      description = "Keys of ~/.config/flox/flox.toml removed at activation.";
    };
    package = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = floxConfig;
      description = "The key-by-key writer, exposed for its suite.";
    };
  };

  config.home.activation.floxConfig = lib.mkIf (args != [ ]) (
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      run ${floxConfig}/bin/flox-config ${lib.escapeShellArg file} ${lib.escapeShellArgs args}
    ''
  );
}
