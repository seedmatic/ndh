# LLM gateway on Darwin (bioskop): llama-swap + LiteLLM, fronting local
# llama-server instances and OpenCode Go.  LaunchAgents run as the primary
# user; secrets come from sops; model weights live in `cfg.dataDir`.
{
  config,
  pkgs,
  lib,
  ndh,
  worktreePath,
  ...
}:
with lib;

let
  cfg = config.services.llmGateway;
  primaryUser = config.system.primaryUser;
  home = config.users.users.${primaryUser}.home;
  dataDir = cfg.dataDir;
  modelsDir = "${dataDir}/models";
  configDir = "${dataDir}/config";
  secretDir = "/run/secrets/nix-darwin-home/llm-secret";

  swapSecret = "swap_api";
  masterSecret = "master";
  goSecret = "go_api";

  swapSecretPath = "${secretDir}/${swapSecret}";
  masterSecretPath = "${secretDir}/${masterSecret}";
  goSecretPath = "${secretDir}/${goSecret}";

  # Config files generated in the nix store and handed to the services.
  swapConfig = pkgs.writeText "llama-swap-config.yaml" ''
    healthCheckTimeout: 500
    logLevel: info
    logTimeFormat: rfc3339
    logToStdout: "both"
    metricsMaxInMemory: 1000
    captureBuffer: 15

    ui:
      activity:
        session_id: ["X-Session-ID", "X-Litellm-Session-Id"]

    performance:
      disabled: false
      every: 15s

    startPort: 5800
    sendLoadingState: false
    globalTTL: 0

    apiKeys:
      - "''${env.LLAMA_SWAP_API_KEY}"

    security:
      cors:
        allowedOrigins: ["*"]

    models:
      agent:
        cmd: >
          llama-server --port ''${PORT} --jinja -np 1
          -hf ${cfg.agentModel}
          --ctx-size 131072
          --temp 0.7 --top-p 0.8 --top-k 20 --repeat-penalty 1.05
          -fa on --cache-type-k q8_0 --cache-type-v q8_0 --cache-reuse 256

      agent-deep:
        cmd: >
          llama-server --port ''${PORT}
          --alias agent-deep
          --jinja -np 1
          -hf TeichAI/Qwen3-30B-A3B-Thinking-2507-Claude-4.5-Sonnet-High-Reasoning-Distill-GGUF:Q4_K_M
          --ctx-size 32768
          -fa on
          --cache-type-k q8_0
          --cache-type-v q8_0
          --cache-reuse 256

      small:
        cmd: >
          llama-server --port ''${PORT} --jinja -np 2
          -hf ggml-org/Qwen2.5-Coder-1.5B-Instruct-Q8_0-GGUF
          --ctx-size 16384 --cache-type-k f16 --cache-type-v f16

      embed:
        cmd: >
          llama-server --port ''${PORT} --embeddings -np 1
          -hf ggml-org/bge-small-en-v1.5-Q8_0-GGUF
          --ctx-size 512 -b 512 -ub 512

    routing:
      router:
        use: group
        settings:
          groups:
            resident:
              swap: false
              exclusive: false
              members: [agent, small, embed]
  '';

  litellmConfig = pkgs.writeText "litellm-config.yaml" ''
    model_list:
      - model_name: local-agent
        litellm_params:
          model: openai/agent
          api_base: http://localhost:8000/v1
          api_key: os.environ/LLAMA_SWAP_API_KEY

      - model_name: local-small
        litellm_params:
          model: openai/small
          api_base: http://localhost:8000/v1
          api_key: os.environ/LLAMA_SWAP_API_KEY

      - model_name: go-deepseek-flash
        litellm_params:
          model: openai/deepseek-v4.1-flash
          api_base: https://opencode.ai/inference/go/openai/v1
          api_key: os.environ/OPENCODE_GO_API_KEY
          extra_headers:
            User-Agent: seedmatic-litellm/1.0

      - model_name: go-qwen-plus
        litellm_params:
          model: openai/qwen3.7-plus
          api_base: https://opencode.ai/inference/go/openai/v1
          api_key: os.environ/OPENCODE_GO_API_KEY
          extra_headers:
            User-Agent: opencode/1.0.41

      - model_name: go-glm-flash
        litellm_params:
          model: openai/glm-5.3-flash
          api_base: https://opencode.ai/inference/go/openai/v1
          api_key: os.environ/OPENCODE_GO_API_KEY
          extra_headers:
            User-Agent: opencode/1.0.41

      - model_name: go-deepseek-free
        litellm_params:
          model: openai/deepseek-v4.1-flash-free
          api_base: https://opencode.ai/zen/v1
          api_key: os.environ/OPENCODE_GO_API_KEY
          extra_headers:
            User-Agent: opencode/1.0.41

    general_settings:
      master_key: os.environ/LITELLM_MASTER_KEY
      trusted_proxy_ranges: []
      cancel_on_disconnect: true

    litellm_settings:
      model_group_settings:
        forward_client_headers_to_llm_api:
          - go-deepseek-flash
          - go-qwen-plus
          - go-glm-flash
          - go-deepseek-free
  '';

  swapLauncher = pkgs.writeShellScript "llm-swap-launcher" ''
    set -euo pipefail
    export PATH="${pkgs.llama-cpp}/bin:${pkgs.llama-swap}/bin:$PATH"
    # Load secrets from sops files into the environment.
    if [ -r "${swapSecretPath}" ]; then
      export LLAMA_SWAP_API_KEY="$(tr -d '[:space:]' < "${swapSecretPath}")"
    fi
    mkdir -p ${lib.escapeShellArg dataDir} ${lib.escapeShellArg modelsDir}
    # llama-server -hf downloads into this cache on first model load.
    export LLAMA_CACHE=${lib.escapeShellArg modelsDir}
    exec ${pkgs.llama-swap}/bin/llama-swap \
      -config ${swapConfig} \
      -listen 0.0.0.0:8000 \
      -watch-config
  '';

  litellmLauncher = pkgs.writeShellScript "litellm-launcher" ''
    set -euo pipefail
    export PATH="${pkgs.python3}/bin:${pkgs.litellm}/bin:$PATH"
    if [ -r "${swapSecretPath}" ]; then
      export LLAMA_SWAP_API_KEY="$(tr -d '[:space:]' < "${swapSecretPath}")"
    fi
    if [ -r "${masterSecretPath}" ]; then
      export LITELLM_MASTER_KEY="$(tr -d '[:space:]' < "${masterSecretPath}")"
    fi
    if [ -r "${goSecretPath}" ]; then
      export OPENCODE_GO_API_KEY="$(tr -d '[:space:]' < "${goSecretPath}")"
    fi
    # Wait for swap to be ready.
    for i in $(seq 1 60); do
      if ${pkgs.curl}/bin/curl -fsS http://127.0.0.1:8000/health >/dev/null 2>&1; then break; fi
      sleep 2
    done
    exec ${pkgs.litellm}/bin/litellm \
      --config ${litellmConfig} \
      --host 0.0.0.0 \
      --port 4000
  '';
in
{
  options.services.llmGateway = {
    enable = mkEnableOption "LLM gateway (llama-swap + LiteLLM) on this Darwin host";

    dataDir = mkOption {
      type = types.str;
      default = "${home}/.local/share/llm-gateway";
      description = "State directory holding model weights and runtime data.";
    };

    agentModel = mkOption {
      type = types.str;
      default = "unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF:Q4_K_M";
      description = "Hugging Face repo[:quant] for the agent model, downloaded into dataDir/models on first use.";
    };

    sopsEncryptedFile = mkOption {
      type = types.path;
      default = worktreePath.of ".secrets";
      description = "sops-encrypted file carrying llm/* keys.";
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = [
      pkgs.llama-cpp
      pkgs.llama-swap
      pkgs.litellm
      pkgs.curl
      pkgs.omo-ai
    ];

    sops.secrets.${swapSecret} = {
      format = "yaml";
      sopsFile = cfg.sopsEncryptedFile;
      key = "llm/llama_swap_api_key";
      path = swapSecretPath;
      owner = primaryUser;
      mode = "0400";
    };
    sops.secrets.${masterSecret} = {
      format = "yaml";
      sopsFile = cfg.sopsEncryptedFile;
      key = "llm/litellm_master_key";
      path = masterSecretPath;
      owner = primaryUser;
      mode = "0400";
    };
    sops.secrets.${goSecret} = {
      format = "yaml";
      sopsFile = cfg.sopsEncryptedFile;
      key = "llm/opencode_go_api_key";
      path = goSecretPath;
      owner = primaryUser;
      mode = "0400";
    };

    launchd.user.agents.llm-swap = {
      command = "${swapLauncher}";
      serviceConfig = {
        Label = "io.seedmatic.ndh.llm-swap";
        KeepAlive = true;
        RunAtLoad = true;
        StandardOutPath = "${home}/Library/Logs/llm-swap.log";
        StandardErrorPath = "${home}/Library/Logs/llm-swap.err.log";
        ProcessType = "Background";
      };
    };

    launchd.user.agents.llm-litellm = {
      command = "${litellmLauncher}";
      serviceConfig = {
        Label = "io.seedmatic.ndh.llm-litellm";
        KeepAlive = true;
        RunAtLoad = true;
        StandardOutPath = "${home}/Library/Logs/llm-litellm.log";
        StandardErrorPath = "${home}/Library/Logs/llm-litellm.err.log";
        ProcessType = "Background";
      };
    };

    ndh.restartOnSecretChange = lib.listToAttrs (
      map
        (
          a:
          lib.nameValuePair a {
            domain = "gui:${primaryUser}";
            secrets = [
              swapSecret
              masterSecret
              goSecret
            ];
            reason = "LLM gateway secret changed";
          }
        )
        [
          "io.seedmatic.ndh.llm-swap"
          "io.seedmatic.ndh.llm-litellm"
        ]
    );
  };
}
