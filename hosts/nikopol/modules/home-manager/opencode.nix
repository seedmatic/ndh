{
  config,
  lib,
  pkgs,
  ...
}:

let
  opencodeSettings = {
    "$schema" = "https://opencode.ai/config.json";
    model = "litellm@nikopol/agent";

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
      "litellm@nikopol" = {
        name = "LiteLLM (nikopol, local)";
        package = "@opencode/ai/providers/openai-compatible";
        settings = {
          baseURL = "http://127.0.0.1:4000/v1";
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
      "aikey@nikopol" = {
        name = "LiteLLM (nikopol, Bedrock)";
        package = "@opencode/ai/providers/openai-compatible";
        settings = {
          baseURL = "http://172.16.16.1:4001/v1";
          apiKey = "aikey";
          chunkTimeout = false;
        };
        models = {
          "claude-sonnet-5-5" = {
            name = "claude-sonnet-5-5";
            limit = {
              context = 1000000;
              output = 64000;
            };
          };
          "claude-opus-5-5" = {
            name = "claude-opus-5-5";
            limit = {
              context = 1000000;
              output = 128000;
            };
          };
          "claude-haiku-4-5" = {
            name = "claude-haiku-4-5";
            limit = {
              context = 200000;
              output = 64000;
            };
          };
        };
      };
    };

    agents = {
      local = {
        mode = "primary";
        model = "litellm@nikopol/agent";
        description = "Local llama.cpp model: Code Mode off, browser tools off";
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
  # Declarative OpenCode configuration for nikopol (corp Mac).
  # Two providers: local gateway (:4000, Qwen) and aikey gateway (:4001, Bedrock/Claude).
  home.activation.seedOpencodeConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    target="$HOME/.config/opencode/opencode.json"
    if [ ! -e "$target" ]; then
      mkdir -p "$(dirname "$target")"
      install -m 0644 ${opencodeConfigFile} "$target"
    fi
  '';
}
