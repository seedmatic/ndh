{
  config,
  lib,
  pkgs,
  worktreePath,
  ...
}:
with lib;
let
  cfg = config.ndh.claude-code;

  specialArgs =
    if config ? _module && config._module ? specialArgs then config._module.specialArgs else { };
  nixBashTrampoline =
    if
      specialArgs ? ndh && specialArgs.ndh ? context && specialArgs.ndh.context ? nixBashTrampoline
    then
      "${specialArgs.ndh.context.nixBashTrampoline}"
    else
      "${worktreePath.of "modules/.common.d/shell.d/nix-bash-trampoline.sh"}";
  profile = config._module.specialArgs.profile;
  userName = profile.user.name;
  loggerTag = "home-manager.activationScripts.${userName}.claudeCodePurgeModelOverride";

  # Bootstrap seed for ~/.claude/settings.json. Written to the Nix store
  # and copied into place ONLY when the file is absent (fresh machine).
  # Once present, Claude Code owns the file — /model, /plugin, and
  # marketplace edits write back to it and we never overwrite them.
  #
  # Intentionally carries only the mutable-but-worth-restoring keys
  # (plugins + marketplaces). The stable model env lives in
  # cfg.env (real shell vars, highest precedence) — NOT here — so the
  # two concerns don't fight.
  #
  # Separately, the legacy env block inside ~/.claude.json (an
  # onboarding-era remnant, a DIFFERENT file Claude owns) can carry an
  # ANTHROPIC_MODEL hard override that pins the model above every
  # settings.json "model" field — defeating the user's chosen default and
  # /model alike. The claudeCodePurgeModelOverride activation below strips
  # that one key so the per-tier defaults here (ANTHROPIC_DEFAULT_OPUS_MODEL)
  # decide the model.
  seedFile = pkgs.writeText "claude-settings-seed.json" (builtins.toJSON cfg.seed);
in
{
  options = {
    ndh.claude-code = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Enable Claude Code stable environment configuration.";
      };

      env = mkOption {
        type = types.attrsOf types.str;
        default = {
          ANTHROPIC_DEFAULT_SONNET_MODEL = "claude-sonnet-4-5-20250929";
          ANTHROPIC_DEFAULT_OPUS_MODEL = "claude-opus-4-8";
          ANTHROPIC_DEFAULT_HAIKU_MODEL = "claude-haiku-4-5-20251001";
        };
        description = ''
          Stable Claude Code configuration exported as real shell
          environment variables.

          Shell env vars take HIGHEST precedence in Claude Code's settings
          layering — above the `env` block of ~/.claude/settings.json — so
          this declarative, read-only set always wins for model
          config.

          Deliberately NOT managed via home.file on settings.json:
          Claude Code writes back to ~/.claude/settings.json at runtime
          (/model, /plugin, marketplaces). Keeping the stable bits here as
          env vars lets that file stay a normal mutable file Claude owns —
          no read-only symlink conflict.
        '';
      };

      seed = mkOption {
        type = types.attrs;
        default = {
          enabledPlugins = {
            "claude-session-driver@superpowers-marketplace" = true;
            "double-shot-latte@superpowers-marketplace" = true;
            "elements-of-style@superpowers-marketplace" = true;
            "episodic-memory@superpowers-marketplace" = true;
            "private-journal-mcp@superpowers-marketplace" = true;
            "superpowers@superpowers-marketplace" = true;
            "superpowers-chrome@superpowers-marketplace" = true;
          };
          extraKnownMarketplaces = {
            superpowers-marketplace = {
              source = {
                source = "github";
                repo = "obra/superpowers-marketplace";
              };
            };
          };
        };
        description = ''
          Bootstrap seed copied to ~/.claude/settings.json only when that
          file does not yet exist (fresh machine). Protects the plugin and
          marketplace list across machine rebuilds without ever clobbering
          the live file Claude mutates at runtime.
        '';
      };
    };
  };

  config = mkIf cfg.enable {
    home.sessionVariables = cfg.env;

    home.activation.claudeCodeSeed = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      claudeSettings="$HOME/.claude/settings.json"
      if [ ! -e "$claudeSettings" ]; then
        $VERBOSE_ECHO "Seeding fresh Claude Code settings.json from flake"
        $DRY_RUN_CMD mkdir -p "$HOME/.claude"
        $DRY_RUN_CMD install -m 0644 ${seedFile} "$claudeSettings"
      else
        $VERBOSE_ECHO "Claude Code settings.json exists — leaving it untouched"
      fi
    '';

    home.activation.claudeCodePurgeModelOverride =
      let
        purgeModelOverrideScript = pkgs.replaceVars ./claude-code.d/purge-anthropic-model.sh {
          nixBashTrampoline = nixBashTrampoline;
          loggerTag = loggerTag;
        };
      in
      lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        $DRY_RUN_CMD ${pkgs.bash}/bin/bash ${purgeModelOverrideScript}
      '';
  };
}
