{
  config,
  lib,
  pkgs,
  ...
}:

let
  # The opencode configuration as a Nix attrset, rendered to JSON by home-manager.
  # Tool pre-selection for the local agent keeps the context window small:
  # only code-essential tools are enabled; heavy/rare ones are denied.
  opencodeSettings = {
    "$schema" = "https://opencode.ai/config.json";
    model = "litellm@bioskop/agent";

    plugins = [
      "superpowers@git+https://github.com/obra/superpowers.git"
    ];

    permissions = [
      {
        action = "browser";
        resource = "*";
        effect = "deny";
      }
    ];

    providers = {
      "litellm@bioskop" = {
        name = "LiteLLM (bioskop)";
        package = "@opencode/ai/providers/openai-compatible";
        settings = {
          baseURL = "http://darwin.bioskop:4000/v1";
          apiKey = "ehlo";
          chunkTimeout = false;
        };
        models = {
          "agent" = {
            name = "agent";
            limit = {
              context = 131072;
              output = 8192;
            };
          };
          "agent-deep" = {
            name = "agent-deep";
            limit = {
              context = 32768;
              output = 4096;
            };
          };
          "small" = {
            name = "small";
            limit = {
              context = 16384;
              output = 4096;
            };
          };
        };
      };
    };

    agents = {
      local = {
        mode = "primary";
        model = "litellm@bioskop/agent";
        description = "Local llama.cpp model: Code Mode off (flat tools), browser tools off";
        permissions = [
          {
            action = "execute";
            resource = "*";
            effect = "deny";
          }
          {
            action = "browser";
            resource = "*";
            effect = "deny";
          }
          {
            action = "skill";
            resource = "browser";
            effect = "deny";
          }
          # Context reduction: deny heavy/rare tools for the local agent
          {
            action = "webfetch";
            resource = "*";
            effect = "deny";
          }
          {
            action = "websearch";
            resource = "*";
            effect = "deny";
          }
          {
            action = "opencode_worktree_create";
            resource = "*";
            effect = "deny";
          }
          {
            action = "opencode_worktree_list";
            resource = "*";
            effect = "deny";
          }
          {
            action = "opencode_worktree_remove";
            resource = "*";
            effect = "deny";
          }
          {
            action = "opencode_list_mcp_resources";
            resource = "*";
            effect = "deny";
          }
          {
            action = "opencode_read_mcp_resource";
            resource = "*";
            effect = "deny";
          }
          {
            action = "opencode_models";
            resource = "*";
            effect = "deny";
          }
          {
            action = "opencode_session_move";
            resource = "*";
            effect = "deny";
          }
          {
            action = "opencode_session_rename";
            resource = "*";
            effect = "deny";
          }
        ];
      };
    };
  };

  opencodeConfigFile = pkgs.writeText "opencode.json" (builtins.toJSON opencodeSettings);
in
{
  # Declarative OpenCode configuration for the primary seat (bioskop).
  # Manages ~/.config/opencode/opencode.json via home-manager (xdg.configFile).
  # The opencode binary itself is installed separately (~/.opencode/bin/opencode);
  # home-manager only owns the config file here.
  # Seed OpenCode config only if absent (preserve runtime tuning).
  home.activation.seedOpencodeConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    target="$HOME/.config/opencode/opencode.json"
    if [ ! -e "$target" ]; then
      mkdir -p "$(dirname "$target")"
      install -m 0644 ${opencodeConfigFile} "$target"
    fi
  '';
}
