# Common to every darwin host: inject the shared Claude Code backend env into the user's launchd session, so
# GUI-launched processes (the VSCode extension host, Dock-launched claude) reach the same backend as login shells,
# which get it via home.sessionVariables (the home-manager claude-code module). Both read one source,
# modules/claude-code-backend-env.nix.
#
# A RunAtLoad agent, not launchd.user.envVariables: nix-darwin applies those
# with a bare `sudo --user=… launchctl setenv`, which targets the CALLER's
# launchd session. From ssh that session is System, not Aqua, and SIP refuses
# it (150), which aborted every darwin switch run over ssh at "setting up user
# launchd services" (measured 2026-10-17). nix-darwin loads agents through
# `launchctl asuser`, so this one runs in the user's GUI domain from ssh too,
# and again at every login, where envVariables only lasted until logout.
{ lib, pkgs, ... }:
let
  backend = import ../claude-code-backend-env.nix;
  setenv = pkgs.writeShellScript "claude-code-backend-env" (
    lib.concatStrings (
      map (name: "/bin/launchctl unsetenv ${name}\n") backend.retired
      ++ lib.mapAttrsToList (
        name: value: "/bin/launchctl setenv ${name} ${lib.escapeShellArg value}\n"
      ) backend.env
    )
  );
in
{
  launchd.user.agents.claude-code-backend-env.serviceConfig = {
    Label = "io.seedmatic.ndh.claude-code-backend-env";
    ProgramArguments = [ "${setenv}" ];
    RunAtLoad = true;
  };
}
