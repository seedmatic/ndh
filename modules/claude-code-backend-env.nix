# Single source of truth for the backend Claude Code talks to, shared by every darwin host: the LLM gateway agent
# of the nikopol vz host, published on nikopol-nixos's fabric gateway address by `ndh.loopbackForward.vzhost-4001`
# (hosts/nikopol/nixos.nix) for the two operator seats only. The agent injects the operator's credential itself, so
# the token below is a placeholder, not a secret.
#
# Three layers consume it, and all three are required:
#   - modules/darwin/claude-code-backend.nix -> a RunAtLoad agent that `launchctl setenv`s `env` in the user's GUI
#     session (the VSCode extension host, Dock-launched claude inherit it);
#   - modules/home-manager/claude-code.nix -> home.sessionVariables (login shells, terminals);
#   - the same module -> the `env` and `fallbackModel` keys of ~/.claude/settings.json, replaced whole at every
#     activation. That block is applied ON TOP of the inherited environment, live (measured 2026-10-10), and it is
#     the only layer that reaches the sessions the VSCode extension launches, so it must carry the same values.
#
# `env` must hold REAL process environment variables: Claude Code selects its backend from the process env.
#
# The model ids are the gateway's names (measured 2026-10-21 through the agent, `GET /v1/models`); it serves no
# Haiku 5.5, so the haiku tier is 4.5. Without the three defaults, a session asks for its built-in ids, which the
# gateway does not know (the session-title call did).
{
  env = {
    ANTHROPIC_BASE_URL = "http://nixos.nikopol:4001";
    ANTHROPIC_AUTH_TOKEN = "aikey";
    ANTHROPIC_DEFAULT_OPUS_MODEL = "claude-opus-5-5";
    ANTHROPIC_DEFAULT_SONNET_MODEL = "claude-sonnet-5-5";
    ANTHROPIC_DEFAULT_HAIKU_MODEL = "claude-haiku-4-5";
    # Claude Code's operational telemetry stays off on both seats (the operator, 2026-10-21): nikopol carried it by
    # hand, and the switch now writes this block whole.
    DISABLE_TELEMETRY = "1";
  };

  # The models tried, in order, when the chosen one is overloaded mid-session. No environment variable carries it.
  fallbackModel = [
    "claude-opus-5"
    "claude-sonnet-5-5"
  ];

  # The keys the former Bedrock backend set. `launchctl setenv` persists until logout, so dropping them from `env`
  # does not remove them from a running GUI session: the agent unsets them.
  retired = [
    "CLAUDE_CODE_USE_BEDROCK"
    "AWS_PROFILE"
    "AWS_REGION"
  ];
}
