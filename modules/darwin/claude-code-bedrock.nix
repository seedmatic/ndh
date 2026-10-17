# Common to every darwin host: inject the shared Bedrock Claude Code env
# into the user's launchd session, so GUI-launched processes (the VSCode
# extension host, Dock-launched claude) resolve AWS Bedrock. Login shells
# get the same values via home.sessionVariables (see the home-manager
# claude-code module) — but that path does NOT cover launchd on darwin,
# hence this second layer reading the same single source.
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
  env = import ../claude-code-bedrock-env.nix;
  setenv = pkgs.writeShellScript "claude-code-bedrock-env" (
    lib.concatStrings (
      lib.mapAttrsToList (name: value: "/bin/launchctl setenv ${name} ${lib.escapeShellArg value}\n") env
    )
  );
in
{
  launchd.user.agents.claude-code-bedrock-env.serviceConfig = {
    Label = "io.seedmatic.ndh.claude-code-bedrock-env";
    ProgramArguments = [ "${setenv}" ];
    RunAtLoad = true;
  };
}
