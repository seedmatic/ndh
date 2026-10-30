# claude-session-cost, built once for the user's PATH and for its check, so both run the same file.
{ pkgs }:
let
  package = pkgs.writeShellScriptBin "claude-session-cost" ''
    exec ${pkgs.python3}/bin/python3 -I ${./session-cost.py} "$@"
  '';
in
{
  inherit package;

  # One session that wrote its cache after a 30 min pause, then read it: the totals, the share and the pause bucket.
  tests =
    pkgs.runCommand "claude-code-session-cost"
      {
        nativeBuildInputs = [
          package
          pkgs.coreutils
          pkgs.gnugrep
        ];
      }
      ''
        mkdir -p home/projects/p
        t() { date -u -d "-$1 min" +%Y-%m-%dT%H:%M:%S.000Z; }
        u() { printf '{"sessionId":"s1","cwd":"/w","timestamp":"%s","message":{"id":"%s","usage":%s}}\n' "$(t "$1")" "$2" "$3"; }
        {
          u 40 m1 '{"input_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":0}'
          u 10 m2 '{"input_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":800000,"cache_creation":{"ephemeral_1h_input_tokens":0},"output_tokens":0}'
          u 9 m3 '{"input_tokens":0,"cache_read_input_tokens":800000,"cache_creation_input_tokens":0,"output_tokens":0}'
          u 9 m3 '{"input_tokens":0,"cache_read_input_tokens":800000,"cache_creation_input_tokens":0,"output_tokens":0}'
        } >home/projects/p/s1.jsonl
        CLAUDE_HOME=$PWD/home claude-session-cost 1 >out
        cat out
        grep -qF 'last 1 h: 1 sessions, 1M units, about $4' out
        grep -qF 're-writes after a pause 93%' out
        grep -qF '5-60m 100%' out
        grep -qE '^s1 +/w +3 +800k' out
        touch $out
      '';
}
