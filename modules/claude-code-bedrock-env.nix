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
# Model ids are cross-region Bedrock inference profiles for the
# ai-tools-shared account (445316526014); verify with
# `aws bedrock list-inference-profiles` if the account changes.
{
  CLAUDE_CODE_USE_BEDROCK = "1";
  AWS_PROFILE = "ai-tools-shared";
  AWS_REGION = "us-east-1";
  ANTHROPIC_DEFAULT_OPUS_MODEL = "us.anthropic.claude-opus-4-8";
  ANTHROPIC_DEFAULT_SONNET_MODEL = "us.anthropic.claude-sonnet-4-6";
  ANTHROPIC_DEFAULT_HAIKU_MODEL = "us.anthropic.claude-haiku-4-5-20251001-v1:0";
}
