# NixOS module: LLM gateway (LiteLLM proxy, optionally + local llama-swap).
# When remoteSwapUrl is set, only LiteLLM runs (proxy to a remote llama-swap).
# When null, both llama-swap and LiteLLM run locally (needs GPU for swap).
{
  config,
  pkgs,
  lib,
  ...
}:
with lib;

let
  cfg = config.services.llmGateway;
  svcUser = "llm-gateway";
  dataDir = cfg.dataDir;
  ndhPrefix = import ./systemd/ndh-prefix.nix { inherit lib; };
  modelsDir = "${dataDir}/models";
  configDir = "${dataDir}/config";

  swapSecret = "llama_swap_api_key";
  masterSecret = "litellm_master_key";
  goSecret = "opencode_go_api_key";
  aikeySecret = "aikey_api_key";

  secretDir = "/run/secrets";
  swapSecretPath = "${secretDir}/${swapSecret}";
  masterSecretPath = "${secretDir}/${masterSecret}";
  goSecretPath = "${secretDir}/${goSecret}";
  aikeySecretPath = "${secretDir}/${aikeySecret}";

  sopsFile = cfg.sopsEncryptedFile;

  # Remote or local llama-swap URL
  swapUrl = if cfg.remoteSwapUrl != null then cfg.remoteSwapUrl else "http://localhost:8000";
  runSwap = cfg.remoteSwapUrl == null;

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
    globalTTL: 1800

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
              members: [agent, agent-deep, small, embed]
  '';

  aikeyModels =
    if cfg.aikeyGatewayUrl != null then
      ''
        - model_name: claude-haiku-4-5
          litellm_params:
            model: openai/claude-haiku-4-5
            api_base: ${cfg.aikeyGatewayUrl}/v1
            api_key: os.environ/AIKEY_API_KEY
      ''
    else
      "";

  litellmConfig = pkgs.writeText "litellm-config.yaml" ''
    model_list:
      - model_name: agent
        litellm_params:
          model: openai/agent
          api_base: ${swapUrl}/v1
          api_key: os.environ/LLAMA_SWAP_API_KEY

      - model_name: agent-deep
        litellm_params:
          model: openai/agent-deep
          api_base: ${swapUrl}/v1
          api_key: os.environ/LLAMA_SWAP_API_KEY

      - model_name: small
        litellm_params:
          model: openai/small
          api_base: ${swapUrl}/v1
          api_key: os.environ/LLAMA_SWAP_API_KEY

      - model_name: embed
        litellm_params:
          model: openai/embed
          api_base: ${swapUrl}/v1
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

      ${aikeyModels}
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
    if [ -r "${swapSecretPath}" ]; then
      export LLAMA_SWAP_API_KEY="$(tr -d '[:space:]' < "${swapSecretPath}")"
    fi
    mkdir -p ${lib.escapeShellArg dataDir} ${lib.escapeShellArg modelsDir} ${lib.escapeShellArg configDir}
    export LLAMA_CACHE=${lib.escapeShellArg modelsDir}
    cp -f /etc/llm-gateway/llama-swap-config.yaml ${lib.escapeShellArg configDir}/llama-swap-config.yaml
    exec ${pkgs.llama-swap}/bin/llama-swap \
      -config ${lib.escapeShellArg "${configDir}/llama-swap-config.yaml"} \
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
    if [ -r "${aikeySecretPath}" ]; then
      export AIKEY_API_KEY="$(tr -d '[:space:]' < "${aikeySecretPath}")"
    fi
    ${
      if runSwap then
        ''
          for i in $(seq 1 60); do
            if ${pkgs.curl}/bin/curl -fsS http://127.0.0.1:8000/health >/dev/null 2>&1; then break; fi
            sleep 2
          done
        ''
      else
        ''
          for i in $(seq 1 30); do
            if ${pkgs.curl}/bin/curl -fsS ${swapUrl}/health >/dev/null 2>&1; then break; fi
            sleep 2
          done
        ''
    }
    cp -f /etc/llm-gateway/litellm-config.yaml ${lib.escapeShellArg configDir}/litellm-config.yaml
    exec ${pkgs.litellm}/bin/litellm \
      --config ${lib.escapeShellArg "${configDir}/litellm-config.yaml"} \
      --host 0.0.0.0 \
      --port 4000
  '';
in
{
  options.services.llmGateway = {
    enable = mkEnableOption "LLM gateway (LiteLLM proxy, optionally + llama-swap) on this NixOS host";

    dataDir = mkOption {
      type = types.str;
      default = "/var/lib/llm-gateway";
      description = "State directory holding model weights and runtime data.";
    };

    agentModel = mkOption {
      type = types.str;
      default = "unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF:Q4_K_M";
      description = "Hugging Face repo[:quant] for the agent model (only used if runSwap).";
    };

    sopsEncryptedFile = mkOption {
      type = types.path;
      default = null;
      description = "Path to sops-encrypted secrets file.";
    };

    aikeyGatewayUrl = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Base URL of an aikey/Bedrock gateway to aggregate.";
    };

    remoteSwapUrl = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "URL of a remote llama-swap instance. If set, only LiteLLM runs (proxy mode).";
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = [
      pkgs.litellm
      pkgs.curl
      pkgs.python3
    ]
    ++ (
      if runSwap then
        [
          pkgs.llama-cpp
          pkgs.llama-swap
        ]
      else
        [ ]
    );

    users.users.${svcUser} = {
      isSystemUser = true;
      group = svcUser;
      home = dataDir;
      createHome = true;
    };
    users.groups.${svcUser} = { };

    sops.secrets.${swapSecret} = {
      sopsFile = cfg.sopsEncryptedFile;
      key = "llm/llama_swap_api_key";
      owner = svcUser;
      mode = "0400";
    };
    sops.secrets.${masterSecret} = {
      sopsFile = cfg.sopsEncryptedFile;
      key = "llm/litellm_master_key";
      owner = svcUser;
      mode = "0400";
    };
    sops.secrets.${goSecret} = {
      sopsFile = cfg.sopsEncryptedFile;
      key = "llm/opencode_go_api_key";
      owner = svcUser;
      mode = "0400";
    };
    sops.secrets.${aikeySecret} = {
      sopsFile = cfg.sopsEncryptedFile;
      key = "llm/aikey_api_key";
      owner = svcUser;
      mode = "0400";
    };

    environment.etc."llm-gateway/litellm-config.yaml" = {
      source = litellmConfig;
      mode = "0644";
    };

    systemd.services = {
      ${ndhPrefix.mkNdhServiceName "llm-litellm"} = {
        description = "LiteLLM proxy";
        after = [
          "network.target"
          "sops-install-secrets.service"
        ]
        ++ (if runSwap then [ "${ndhPrefix.mkNdhServiceName "llm-swap"}.service" ] else [ ]);
        wants = [ "sops-install-secrets.service" ];
        requires = if runSwap then [ "${ndhPrefix.mkNdhServiceName "llm-swap"}.service" ] else [ ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "simple";
          User = svcUser;
          Group = svcUser;
          ExecStart = "${litellmLauncher}";
          Restart = "always";
          RestartSec = 5;
        };
      };
    }
    // (
      if runSwap then
        {
          ${ndhPrefix.mkNdhServiceName "llm-swap"} = {
            description = "llama-swap LLM server";
            after = [
              "network.target"
              "sops-install-secrets.service"
            ];
            wants = [ "sops-install-secrets.service" ];
            wantedBy = [ "multi-user.target" ];
            serviceConfig = {
              Type = "simple";
              User = svcUser;
              Group = svcUser;
              ExecStart = "${swapLauncher}";
              Restart = "always";
              RestartSec = 5;
            };
          };
        }
      else
        { }
    );

    systemd.tmpfiles.rules = [
      "d ${dataDir} 0755 ${svcUser} ${svcUser} -"
      "d ${modelsDir} 0755 ${svcUser} ${svcUser} -"
      "d ${configDir} 0755 ${svcUser} ${svcUser} -"
    ]
    ++ (
      if runSwap then
        [
          "L+ /etc/llm-gateway/llama-swap-config.yaml - - - - ${swapConfig}"
        ]
      else
        [ ]
    );

    environment.etc."llm-gateway/llama-swap-config.yaml" = mkIf runSwap {
      source = swapConfig;
      mode = "0644";
    };
  };
}
