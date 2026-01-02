{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.programs.githubMcpProxy;
  # Store the python source separately and wrap with a shell launcher so we don't duplicate shebangs.
  pythonSource = pkgs.writeText "github-mcp-proxy.py" (builtins.readFile ./github-mcp-proxy.py);
  wrapped = pkgs.writeShellScriptBin "github-mcp-proxy" ''
    exec ${pkgs.python3}/bin/python3 ${pythonSource} "$@"
  '';
  githubMcpProxyActivationScript = pkgs.writeShellScript "github-mcp-proxy-activation.sh" (
    builtins.readFile ./github-mcp-proxy.d/activation.sh
  );
in
{
  options.programs.githubMcpProxy = {
    # Enable by default when the module is imported; hosts can override with = false.
    enable =
      (mkEnableOption "Local stdio JSON-RPC proxy for the GitHub Copilot MCP endpoint (no static token).")
      // {
        default = true;
      };
    package = mkOption {
      type = types.package;
      default = wrapped;
      readOnly = true;
      description = "Derivation providing the github-mcp-proxy executable.";
    };
    remoteUrl = mkOption {
      type = types.str;
      default = "https://api.githubcopilot.com/mcp";
      description = "Upstream MCP endpoint base URL.";
    };
    tokenCommand = mkOption {
      type = types.str;
      default = "gh auth token";
      description = "Command used to obtain a GitHub access token (stdout).";
    };
    tokenTtlSeconds = mkOption {
      type = types.int;
      default = 300;
      description = "In-memory token cache TTL in seconds.";
    };
    extraEnvironment = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = "Extra environment variables to export (merged).";
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = [
      cfg.package
      pkgs.gh
      pkgs.python3
    ];

    # Provide environment variables so the script can rely on defaults without CLI flags.
    environment.variables = {
      GITHUB_MCP_REMOTE_URL = cfg.remoteUrl;
      GITHUB_MCP_TOKEN_COMMAND = cfg.tokenCommand;
      GITHUB_MCP_TOKEN_TTL = toString cfg.tokenTtlSeconds;
    }
    // cfg.extraEnvironment;

    # Optional: simple activation health check (non-fatal)
    system.activationScripts.postActivation.text = lib.mkAfter ''
      ${githubMcpProxyActivationScript}
    '';
  };
}
