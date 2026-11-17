# LLM gateway on Darwin (bioskop): llama-swap only, fronting local
# llama-server instances.  LaunchAgent runs as the primary user; secrets
# come from sops; model weights live in `cfg.dataDir`.  LiteLLM (the
# proxy/router) is hosted on NixOS peers, not here.
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

  secretDir = "/run/secrets/nix-darwin-home/llm-secret";
  swapSecret = "swap_api";
  swapSecretPath = "${secretDir}/${swapSecret}";

  # Config file: template externalised in llm-gateway.d/, with @AGENT_MODEL@.
  swapConfig = pkgs.replaceVars ./llm-gateway.d/llama-swap-config.yaml {
    AGENT_MODEL = cfg.agentModel;
  };

  swapLauncher = pkgs.writeShellScript "llm-swap-launcher" ''
    set -euo pipefail
    export PATH="${pkgs.llama-cpp}/bin:${pkgs.llama-swap}/bin:$PATH"
    if [ -r "${swapSecretPath}" ]; then
      export LLAMA_SWAP_API_KEY="$(tr -d '[:space:]' < "${swapSecretPath}")"
    fi
    mkdir -p ${lib.escapeShellArg dataDir} ${lib.escapeShellArg modelsDir} "${home}/Library/LaunchAgents"
    export LLAMA_CACHE=${lib.escapeShellArg modelsDir}
    exec ${pkgs.llama-swap}/bin/llama-swap \
      -config ${lib.escapeShellArg "${home}/Library/LaunchAgents/io.seedmatic.ndh.llm-swap.config.yaml"} \
      -listen 0.0.0.0:8000 \
      -watch-config
  '';
in
{
  options.services.llmGateway = {
    enable = mkEnableOption "LLM gateway (llama-swap) on this Darwin host";

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
      pkgs.curl
    ];

    sops.secrets.${swapSecret} = {
      format = "yaml";
      sopsFile = cfg.sopsEncryptedFile;
      key = "llm/llama_swap_api_key";
      path = swapSecretPath;
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

    ndh.restartOnSecretChange = lib.listToAttrs (
      map (
        a:
        lib.nameValuePair a {
          domain = "gui:${primaryUser}";
          secrets = [ swapSecret ];
          reason = "LLM gateway secret changed";
        }
      ) [ "io.seedmatic.ndh.llm-swap" ]
    );

    system.activationScripts.preActivation.text = lib.mkBefore ''
      mkdir -p "${home}/Library/LaunchAgents"
      ln -sfn ${swapLauncher} "${home}/Library/LaunchAgents/io.seedmatic.ndh.llm-swap.sh"
      chown -h ${primaryUser}:staff "${home}/Library/LaunchAgents/io.seedmatic.ndh.llm-swap.sh"
    '';

    system.activationScripts.postActivation.text = lib.mkAfter ''
      set -eu
      if [ ! -f "${home}/Library/LaunchAgents/io.seedmatic.ndh.llm-swap.config.yaml" ]; then
        mkdir -p "${home}/Library/LaunchAgents"
        cp ${swapConfig} "${home}/Library/LaunchAgents/io.seedmatic.ndh.llm-swap.config.yaml"
        chown ${primaryUser}:staff "${home}/Library/LaunchAgents/io.seedmatic.ndh.llm-swap.config.yaml"
      fi
    '';
  };
}
