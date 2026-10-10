# Single source of truth for the AWS Bedrock Claude Code environment,
# shared by every darwin host. Two layers consume it, and BOTH are
# required on darwin because home.sessionVariables alone does not reach
# GUI apps launched by launchd (the VSCode extension host, Dock-launched
# claude):
#   - modules/darwin/claude-code-bedrock.nix -> launchd.user.envVariables
#     (the login launchd session; GUI apps inherit it)
#   - modules/home-manager/claude-code.nix   -> home.sessionVariables
#     (login shells / terminals)
#
# These must be REAL process environment variables: Claude Code only
# selects the Bedrock backend and resolves AWS credentials from the
# process env, not from the `env` block of ~/.claude/settings.json.
#
# That block does NOT lose to this environment — it is applied on top of
# it, and live (measured 2026-10-10: a running session switched ids
# between two turns when the block was edited). It is also the ONLY layer
# that reaches sessions the VSCode extension launches: the extension passes
# the binary's built-in Bedrock defaults (us.…sonnet-4-6, a dated
# haiku-4-5) to the `claude` it spawns, whatever its own host inherited
# from here. So the three model ids are set in BOTH places, with the same
# values: here for terminals, and in that block for the extension. Change
# them together.
#
# The ids are `global.` inference profiles, so AWS routes each request to
# any region with capacity. A `us.` profile is confined to us-east-1,
# us-east-2 and us-west-2, which saturated under load. Being fully
# qualified, these need no ANTHROPIC_BEDROCK_REGION_PREFIX. Capacity is
# not the same thing as a model being served: list what this account can
# actually reach with `aws bedrock list-inference-profiles`.
#
# A model that is overloaded mid-session is handled separately, by
# `fallbackModel` in ~/.claude/settings.json: it has no environment
# variable, so it cannot live here.
{
  CLAUDE_CODE_USE_BEDROCK = "1";
  AWS_PROFILE = "ai-tools-shared";
  AWS_REGION = "us-east-1";
  ANTHROPIC_DEFAULT_OPUS_MODEL = "global.anthropic.claude-opus-5-5";
  ANTHROPIC_DEFAULT_SONNET_MODEL = "global.anthropic.claude-sonnet-5-5";
  ANTHROPIC_DEFAULT_HAIKU_MODEL = "global.anthropic.claude-haiku-5-5";
}
