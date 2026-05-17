# Helper that turns a Nix attrset (the headscale config) into a YAML file
# via yq (json → yaml round-trip).  Both the Darwin and NixOS peers of
# the headscale daemon module call this with their platform-specific
# values.
#
# Why yq instead of writing YAML by hand: every previous attempt to
# string-concat YAML has hit indentation footguns (heredoc strip-indent,
# list element columns, list-of-maps nesting).  yq's JSON → YAML emitter
# never gets those wrong, and the JSON producer is just `builtins.toJSON`
# on a Nix attrset — so values stay typed and the renderer has zero
# string-shaping logic.
{
  pkgs,
  ndh,
  ...
}:
let
  ndhStore = ndh.store;
  trampolineDir = builtins.dirOf ndh.context.nixBashTrampoline;

  # `name`: store-name suffix; the wrapper drv ends up as
  # io-nxmatic-nix-darwin-home-<name>-headscale-config.yaml.
  # `configValue`: the headscale config as a Nix attrset.  Keys map
  # directly to headscale's config schema; nested attrs become nested
  # YAML, lists become YAML lists.
  build = { name, configValue }:
    let
      configJson = pkgs.writeText "${name}-headscale-config.json"
        (builtins.toJSON configValue);
      renderScript = ndhStore.installScript {
        name = "${name}-render-headscale-config.sh";
        source = pkgs.replaceVars ./render-config.sh {
          nixBashTrampoline = "${trampolineDir}/nix-bash-trampoline.sh";
          loggerTag = "headscale-daemon.${name}.render-config";
          configJson = "${configJson}";
        };
        preferLocalBuild = true;
        allowSubstitutes = false;
        mode = "0755";
      };
    in
    ndhStore.runCommand "${name}-headscale-config.yaml" {
      nativeBuildInputs = [ pkgs.yq-go pkgs.bash ];
    } ''
      ${renderScript} "$out"
    '';
in
{
  inherit build;
}
