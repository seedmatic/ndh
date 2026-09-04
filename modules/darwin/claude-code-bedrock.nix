# Common to every darwin host: inject the shared Bedrock Claude Code env
# into the user's launchd session, so GUI-launched processes (the VSCode
# extension host, Dock-launched claude) resolve AWS Bedrock. Login shells
# get the same values via home.sessionVariables (see the home-manager
# claude-code module) — but that path does NOT cover launchd on darwin,
# hence this second layer reading the same single source.
{ ... }:
{
  launchd.user.envVariables = import ../claude-code-bedrock-env.nix;
}
