{
  config,
  lib,
  pkgs,
  ...
}:

let
  modelsJson = builtins.toJSON {
    providers = {
      "litellm-nikopol" = {
        baseUrl = "http://127.0.0.1:4000/v1";
        api = "openai-completions";
        apiKey = "ehlo";
        compat = {
          supportsDeveloperRole = false;
          supportsReasoningEffort = false;
        };
        models = [
          {
            id = "agent";
            name = "Agent (30B, local)";
            reasoning = false;
            input = [ "text" ];
            contextWindow = 131072;
            maxTokens = 8192;
          }
          {
            id = "agent-deep";
            name = "Agent Deep (30B, local)";
            reasoning = true;
            input = [ "text" ];
            contextWindow = 32768;
            maxTokens = 4096;
          }
          {
            id = "small";
            name = "Small (1.5B, local)";
            reasoning = false;
            input = [ "text" ];
            contextWindow = 16384;
            maxTokens = 2048;
          }
        ];
      };
      "aikey-nikopol" = {
        baseUrl = "http://nixos.nikopol:4001/v1";
        api = "openai-completions";
        apiKey = "aikey";
        compat = {
          supportsDeveloperRole = false;
          supportsReasoningEffort = false;
        };
        models = [
          {
            id = "claude-sonnet-5-5";
            name = "Claude Sonnet 5.5 (Bedrock)";
            reasoning = false;
            input = [ "text" ];
            contextWindow = 1000000;
            maxTokens = 64000;
          }
          {
            id = "claude-opus-5-5";
            name = "Claude Opus 5.5 (Bedrock)";
            reasoning = true;
            input = [ "text" ];
            contextWindow = 1000000;
            maxTokens = 128000;
          }
          {
            id = "claude-haiku-4-5";
            name = "Claude Haiku 4.5 (Bedrock)";
            reasoning = false;
            input = [ "text" ];
            contextWindow = 200000;
            maxTokens = 64000;
          }
        ];
      };
    };
  };

  settingsJson = builtins.toJSON {
    defaultProvider = "litellm-nikopol";
    defaultModel = "agent";
    enabledModels = [
      "litellm-nikopol/*"
      "aikey-nikopol/*"
    ];
  };

  modelsJsonFile = pkgs.writeText "models.json" modelsJson;
  settingsJsonFile = pkgs.writeText "settings.json" settingsJson;
  omoJsoncFile = ./omo.jsonc;
in
{
  # Declarative omo (AI coding assistant) configuration for nikopol (corp Mac).
  # Two providers: local gateway (Qwen, :4000) and aikey gateway (Bedrock/Claude, :4001).
  home.activation.seedOmoConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    for spec in "models.json:${modelsJsonFile}" "settings.json:${settingsJsonFile}"; do
      name="''${spec%%:*}"
      src="''${spec#*:}"
      target="$HOME/.omo/agent/$name"
      if [ ! -e "$target" ]; then
        mkdir -p "$(dirname "$target")"
        install -m 0644 "$src" "$target"
      fi
    done
    # omo.jsonc lives at $HOME/.omo/omo.jsonc (not under agent/)
    if [ ! -e "$HOME/.omo/omo.jsonc" ]; then
      mkdir -p "$HOME/.omo"
      install -m 0644 "${omoJsoncFile}" "$HOME/.omo/omo.jsonc"
    fi
  '';
}
