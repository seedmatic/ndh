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
      "${worktreePath.runtimeFile "modules/.common.d/shell.d/nix-bash-trampoline.sh"}";
  profile = config._module.specialArgs.profile;
  userName = profile.user.name;
  loggerTag = "home-manager.activationScripts.${userName}.claudeCodePurgeModelOverride";

  # Bootstrap seed for ~/.claude/settings.json. Written to the Nix store
  # and copied into place ONLY when the file is absent (fresh machine).
  # Once present, Claude Code owns the file — /model, /plugin, and
  # marketplace edits write back to it and we never overwrite them.
  #
  # Intentionally carries only the model ALIAS, and no plugin: the operator
  # enables those one at a time, knowing what each changes. The alias picks the tier
  # and the context window; the `[1m]` suffix exists nowhere else, so
  # without it a fresh machine falls back to 200k. The Bedrock model id
  # behind the tier lives in cfg.env (real shell vars, highest precedence)
  # — NOT here — so the two concerns don't fight.
  #
  # Separately, the legacy env block inside ~/.claude.json (an
  # onboarding-era remnant, a DIFFERENT file Claude owns) can carry an
  # ANTHROPIC_MODEL hard override that pins the model above every
  # settings.json "model" field — defeating the user's chosen default and
  # /model alike. The claudeCodePurgeModelOverride activation below strips
  # that one key so the per-tier defaults here (ANTHROPIC_DEFAULT_OPUS_MODEL)
  # decide the model.
  seedFile = pkgs.writeText "claude-settings-seed.json" (builtins.toJSON cfg.seed);

  # The session hooks own the `hooks` key of ~/.claude/settings.json and nothing else: the file stays
  # Claude's, and this block is replaced whole at every activation, so a hook removed here is gone.
  sessionHooks = import ./claude-code.d/hooks/package.nix { inherit pkgs; };
  hooksFile = pkgs.writeText "claude-code-hooks.json" (builtins.toJSON sessionHooks.hooks);
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
        default = import ../claude-code-bedrock-env.nix;
        description = ''
          Stable Claude Code configuration exported as real shell
          environment variables — the AWS Bedrock backend selection and
          per-tier model ids, shared with the launchd session via the
          darwin claude-code-bedrock module (single source:
          modules/claude-code-bedrock-env.nix).

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

      sessionHooks.enable = mkEnableOption "the session hooks (memory guard and commit, checkpoints) in ~/.claude/settings.json";

      seed = mkOption {
        type = types.attrs;
        default = {
          model = "opus[1m]";
        };
        description = ''
          Bootstrap seed copied to ~/.claude/settings.json only when that
          file does not yet exist (fresh machine), so the model alias survives a
          rebuild without ever clobbering the live file Claude mutates at runtime.
        '';
      };
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      home.sessionVariables = cfg.env;
    }

    (mkIf cfg.sessionHooks.enable {
      home.activation.claudeCodeHooks = lib.hm.dag.entryAfter [ "writeBoundary" "claudeCodeSeed" ] ''
        claudeSettings="$HOME/.claude/settings.json"
        if [ -f "$claudeSettings" ]; then
          claudeSettingsNew="$(mktemp)"
          ${pkgs.jq}/bin/jq --slurpfile hooks ${hooksFile} '.hooks = $hooks[0]' "$claudeSettings" >"$claudeSettingsNew"
          $DRY_RUN_CMD install -m 0644 "$claudeSettingsNew" "$claudeSettings"
          rm -f "$claudeSettingsNew"
        fi
      '';
    })

    {
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
    }
  ]);
}
