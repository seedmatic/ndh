{
  config,
  lib,
  pkgs,
  ...
}:

let
  modelsJson = builtins.toJSON {
    providers = {
      "litellm-bioskop" = {
        baseUrl = "http://darwin.bioskop:4000/v1";
        api = "openai-completions";
        apiKey = "ehlo";
        compat = {
          supportsDeveloperRole = false;
          supportsReasoningEffort = false;
        };
        models = [
          {
            id = "agent";
            name = "Agent (30B)";
            reasoning = false;
            input = [ "text" ];
            contextWindow = 131072;
            maxTokens = 8192;
          }
          {
            id = "agent-deep";
            name = "Agent Deep (30B)";
            reasoning = true;
            input = [ "text" ];
            contextWindow = 32768;
            maxTokens = 4096;
          }
          {
            id = "small";
            name = "Small (1.5B)";
            reasoning = false;
            input = [ "text" ];
            contextWindow = 16384;
            maxTokens = 2048;
          }
        ];
      };
    };
  };

  settingsJson = builtins.toJSON {
    defaultProvider = "litellm-bioskop";
    defaultModel = "agent";
    enabledModels = [ "litellm-bioskop/*" ];
  };

  modelsJsonFile = pkgs.writeText "models.json" modelsJson;
  settingsJsonFile = pkgs.writeText "settings.json" settingsJson;
  omoJsoncFile = ./omo.jsonc;
in
{
  # Declarative omo (AI coding assistant) configuration for the primary seat.
  # Uses the local LLM gateway (litellm -> llama-swap -> llama-server) by default.
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
