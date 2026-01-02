# NixOS module to enable and configure code-server
# @codebase
{
  config,
  pkgs,
  lib,
  ...
}:
{
  options.code-server = {
    port = lib.mkOption {
      type = lib.types.int;
      default = 8080;
      description = "Port for code-server to listen on.";
    };
  };

  config = {
    services.code-server = {
      enable = false;
      port = config.code-server.port;
      host = "0.0.0.0";
    };
  };
}
