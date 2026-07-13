# Per-host bridge: imports the home-manager-scope developer-tools
# module on nikopol only. Lives in modules/darwin/ so the host-name
# guard fires at system-config evaluation.
#
# Enables:
#   - Claude Code stable env (model vars; settings.json left mutable)
#   - Comet browser with Chrome DevTools remote debugging (port 9222)
{
  config,
  lib,
  ...
}:
{
  hm.imports = lib.optional (
    config.profile.host.hostName == "nikopol"
  ) ../home-manager/developer-tools.nix;
}
