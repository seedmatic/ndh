# The ~/.claude.json backend purge, built once for the activation and for its check, so both run the same file.
{
  pkgs,
  nixBashTrampoline,
  loggerTag,
}:
let
  # The keys that select or configure a backend: settings.json's `env` block owns them.
  backendKeys = "^(CLAUDE_CODE_USE_BEDROCK|CLAUDE_CODE_USE_VERTEX|AWS_|ANTHROPIC_)";
  script = pkgs.replaceVars ./purge-backend-env.sh {
    inherit nixBashTrampoline loggerTag backendKeys;
  };
in
{
  inherit script;

  # A seat's file as the Bedrock backend left it: every backend key goes, the rest of the file stays byte for byte in
  # meaning, and a clean file is not rewritten.
  tests =
    let
      # The trampoline only sources the logger and re-execs under nix bash; the check runs the purge itself.
      stub = pkgs.writeText "trampoline-stub.sh" ''
        ndh::logger:command:run() { shift; "$@"; }
      '';
      testScript = pkgs.replaceVars ./purge-backend-env.sh {
        nixBashTrampoline = stub;
        loggerTag = "test";
        inherit backendKeys;
      };
    in
    pkgs.runCommand "claude-code-purge-backend-env"
      {
        nativeBuildInputs = [
          pkgs.bash
          pkgs.jq
          pkgs.yq-go
          pkgs.coreutils
        ];
      }
      ''
        export HOME=$TMPDIR/home
        mkdir -p $HOME
        cat >$HOME/.claude.json <<'EOF'
        {"numStartups": 12, "projects": {"/a": {"allowedTools": []}},
         "env": {"CLAUDE_CODE_USE_BEDROCK": "1", "AWS_PROFILE": "p", "AWS_REGION": "us-east-1",
                 "ANTHROPIC_MODEL": "m", "ANTHROPIC_BASE_URL": "u", "CLAUDE_CODE_USE_VERTEX": "1",
                 "CLAUDE_CODE_MAX_OUTPUT_TOKENS": "64000", "MAX_THINKING_TOKENS": "31999"}}
        EOF
        before="$(jq -S 'del(.env)' $HOME/.claude.json)"
        bash ${testScript}

        left="$(jq -r --arg re '${backendKeys}' '.env | keys[] | select(test($re))' $HOME/.claude.json)"
        if [ -n "$left" ]; then echo "FAIL: backend keys left: $left" >&2; exit 1; fi
        [ "$(jq -c '.env' $HOME/.claude.json)" = '{"CLAUDE_CODE_MAX_OUTPUT_TOKENS":"64000","MAX_THINKING_TOKENS":"31999"}' ] ||
          { echo "FAIL: the other env keys did not survive" >&2; jq . $HOME/.claude.json >&2; exit 1; }
        [ "$(jq -S 'del(.env)' $HOME/.claude.json)" = "$before" ] ||
          { echo "FAIL: the rest of the file changed" >&2; exit 1; }

        # A clean file is left untouched: not even rewritten.
        printf '%s\n' '{ "numStartups": 1,   "env": {"MAX_THINKING_TOKENS": "1"} }' >$HOME/.claude.json
        sum="$(sha256sum $HOME/.claude.json)"
        bash ${testScript}
        [ "$(sha256sum $HOME/.claude.json)" = "$sum" ] || { echo "FAIL: a clean file was rewritten" >&2; exit 1; }

        # No env block, and no file at all: both are no-ops.
        printf '%s\n' '{"numStartups": 1}' >$HOME/.claude.json
        bash ${testScript}
        [ "$(jq -c . $HOME/.claude.json)" = '{"numStartups":1}' ] || { echo "FAIL: a file without env changed" >&2; exit 1; }
        rm $HOME/.claude.json
        bash ${testScript}
        if [ -e $HOME/.claude.json ]; then echo "FAIL: the purge created ~/.claude.json" >&2; exit 1; fi
        touch $out
      '';
}
