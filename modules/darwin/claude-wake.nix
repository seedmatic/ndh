{
  config,
  lib,
  pkgs,
  ...
}:
# ndh-claude-wake on the operator seat's PATH: after a cold restart, the integration (🎛️ operations as its fallback)
# reopens every session security engraved, each in its VS Code workspace, reading the installed registry.
let
  cfg = config.ndh.claudeWake;
in
{
  options.ndh.claudeWake = {
    enable = lib.mkEnableOption "ndh-claude-wake, which reopens the engraved Claude sessions after a cold restart";
    bundle = lib.mkOption {
      type = lib.types.str;
      default = "com.microsoft.VSCodeInsiders";
      description = "The VS Code build the sessions live in, by its bundle id (LaunchServices opens their workspaces).";
    };
    scheme = lib.mkOption {
      type = lib.types.str;
      default = "vscode-insiders";
      description = "That build's URL scheme, which the Claude extension's open?session= link goes through.";
    };
    package = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = import ../.common.d/claude-wake.d/package.nix {
        inherit pkgs;
        inherit (cfg) bundle scheme;
        registry = "${
          (import ./claude-code-managed.d/package.nix { inherit pkgs; }).hookDir
        }/owned-dirs.json";
      };
      description = "ndh-claude-wake, built for this seat's VS Code and its installed registry.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];
  };
}
