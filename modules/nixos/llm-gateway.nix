# NixOS module: LLM gateway (LiteLLM proxy only).
# LiteLLM runs here and proxies to a llama-swap instance.  On this fleet
# llama-swap is carried by the Darwin peers, so `remoteSwapUrl` points at
# one of them (e.g. http://darwin.nikopol:8000); a null value keeps the
# historical localhost default for single-host setups.
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

  swapUrl = if cfg.remoteSwapUrl != null then cfg.remoteSwapUrl else "http://localhost:8000";

  aikeyModels =
    if cfg.aikeyGatewayUrl != null then
      ''
        # Bedrock/Claude models aggregated from the aikey gateway (${cfg.aikeyGatewayUrl}).
        - model_name: claude-haiku-4-5
          litellm_params:
            model: openai/claude-haiku-4-5
            api_base: ${cfg.aikeyGatewayUrl}/v1
            api_key: os.environ/AIKEY_API_KEY

        - model_name: claude-sonnet-4-5
          litellm_params:
            model: openai/claude-sonnet-4-5
            api_base: ${cfg.aikeyGatewayUrl}/v1
            api_key: os.environ/AIKEY_API_KEY

        - model_name: claude-sonnet-5-5
          litellm_params:
            model: openai/claude-sonnet-5-5
            api_base: ${cfg.aikeyGatewayUrl}/v1
            api_key: os.environ/AIKEY_API_KEY

        - model_name: claude-opus-5-5
          litellm_params:
            model: openai/claude-opus-5-5
            api_base: ${cfg.aikeyGatewayUrl}/v1
            api_key: os.environ/AIKEY_API_KEY

      ''
    else
      "";

  # Config template externalised in llm-gateway.d/.
  litellmConfig = pkgs.replaceVars ./llm-gateway.d/litellm-config.yaml {
    SWAP_URL = swapUrl;
    AIKEY_MODELS = aikeyModels;
  };

  opencodeSessionHookDir = pkgs.writeTextDir "opencode_session_hook.py" (
    builtins.readFile ./llm-gateway.d/opencode_session_hook.py
  );

  litellmLauncher = pkgs.writeShellScript "litellm-launcher" ''
    set -euo pipefail
    export PATH="${pkgs.python3}/bin:${pkgs.litellm}/bin:$PATH"
    export PYTHONPATH="${opencodeSessionHookDir}''${PYTHONPATH:+:$PYTHONPATH}"
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
    for i in $(seq 1 30); do
      if ${pkgs.curl}/bin/curl -fsS ${swapUrl}/health >/dev/null 2>&1; then break; fi
      sleep 2
    done
    exec ${pkgs.litellm}/bin/litellm \
      --config /etc/llm-gateway/litellm-config.yaml \
      --host 0.0.0.0 \
      --port 4000
  '';
in
{
  options.services.llmGateway = {
    enable = mkEnableOption "LLM gateway (LiteLLM proxy) on this NixOS host";

    dataDir = mkOption {
      type = types.str;
      default = "/var/lib/llm-gateway";
      description = "State directory holding model weights and runtime data.";
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
      description = "URL of the llama-swap instance to proxy (usually a Darwin peer).";
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = [
      pkgs.litellm
      pkgs.curl
      pkgs.python3
    ];

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
      ${ndhPrefix.mkNdhUnitName "llm-litellm"} = {
        description = "LiteLLM proxy";
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
          ExecStart = "${litellmLauncher}";
          Restart = "always";
          RestartSec = 5;
        };
      };
    };

    systemd.tmpfiles.rules = [
      "d ${dataDir} 0755 ${svcUser} ${svcUser} -"
      "d ${modelsDir} 0755 ${svcUser} ${svcUser} -"
      "d ${configDir} 0755 ${svcUser} ${svcUser} -"
    ];

    # Ensure /etc/llm-gateway/litellm-config.yaml exists (provided by environment.etc).
  };
}
