# Claude Code managed settings: the deny/ask list and the PreToolUse hook that no session, mode or
# lower settings level can lift. Both come from one verb table, claude-code-managed.d/verbs.json.
#
# Two failure modes shape this module, both silent:
#   - a managed-settings.json that is not world-readable leaves every session WITHOUT the policy and
#     with no error, hence `install -m 0644`;
#   - an invalid JSON stops EVERY session from starting, hence the `jq -e` in the derivation, and the
#     list checker, which fails the build on an open gap or a false positive.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  managed = import ./claude-code-managed.d/package.nix { inherit pkgs; };

  target = "/Library/Application Support/ClaudeCode/managed-settings.json";
in
{
  # Off unless a host turns it on: a machine under an employer's MDM may carry its own Claude Code
  # policy, which is theirs and not to be doubled.
  options.ndh.claude-code.managedSettings.enable =
    lib.mkEnableOption "the Claude Code managed deny/ask list and PreToolUse hook";

  config = lib.mkIf config.ndh.claude-code.managedSettings.enable {
    system.activationScripts.postActivation.text = lib.mkAfter ''
      install -d -m 0755 "${builtins.dirOf target}"
      install -m 0644 ${managed.settings} "${target}"
    '';
  };
}
