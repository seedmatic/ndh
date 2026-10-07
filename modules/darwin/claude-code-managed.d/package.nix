# The managed settings file and the bats run of its hook, built from verbs.json. Shared by the
# darwin module, which installs the file, and the flake's checks, which build both.
{ pkgs }:
let
  src = ./.;
  python = pkgs.python3;

  hookDir = pkgs.runCommand "claude-code-deny-hook" { } ''
    mkdir -p $out
    cp ${src}/deny-hook.py ${src}/verbs.json $out/
  '';
in
{
  settings =
    pkgs.runCommand "claude-code-managed-settings.json"
      {
        nativeBuildInputs = [
          python
          pkgs.jq
        ];
      }
      ''
        python3 -I ${src}/gen-managed-settings.py list.json
        python3 -I ${src}/tests/check-list.py list.json
        # A hook that crashes lets the call through, so the interpreter is the store's, never PATH's.
        jq -e --arg hook "${python}/bin/python3 -I ${hookDir}/deny-hook.py" '
          . + {hooks: {PreToolUse: [{matcher: "Bash", hooks: [{type: "command", command: $hook, timeout: 10}]}]}}
        ' list.json > $out
      '';

  tests =
    pkgs.runCommand "claude-code-deny-hook-bats"
      {
        nativeBuildInputs = [
          pkgs.bats
          pkgs.jq
          python
        ];
      }
      ''
        cp -r ${src} src && chmod -R u+w src
        cd src/tests && bats deny-hook.bats
        touch $out
      '';
}
