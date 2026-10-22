# The managed settings file and the bats run of its hook, built from verbs.json. Shared by the
# darwin module, which installs the file, and the flake's checks, which build both.
{ pkgs }:
let
  src = ./.;
  python = pkgs.python3;

  # The deletion areas security engraves, written in YAML and handed to the hook as JSON; until the registry
  # lands, no session has one. One conversion, the same for the hook and for its check.
  hasOwned = builtins.pathExists ./owned-dirs.yaml;
  ownedToJson = yaml: json: ''
    ${pkgs.yq-go}/bin/yq -o=json '.' ${yaml} > ${json}
    ${python}/bin/python3 -I ${src}/tests/check-owned-dirs.py ${json}
  '';

  hookDir = pkgs.runCommand "claude-code-deny-hook" { } (
    ''
      mkdir -p $out
      cp ${src}/deny-hook.py ${src}/verbs.json $out/
    ''
    + pkgs.lib.optionalString hasOwned (ownedToJson "${src}/owned-dirs.yaml" "$out/owned-dirs.json")
  );
in
{
  # The installed registry (owned-dirs.json) lives here: the session hooks read session names from it.
  inherit hookDir;

  settings =
    pkgs.runCommand "claude-code-managed-settings.json"
      {
        nativeBuildInputs = [
          python
          pkgs.yq-go
        ];
      }
      ''
        python3 -I ${src}/gen-managed-settings.py list.json
        python3 -I ${src}/tests/check-list.py list.json
        # A hook that crashes lets the call through, so the interpreter is the store's, never PATH's.
        HOOK="${python}/bin/python3 -I ${hookDir}/deny-hook.py" yq -p=json -o=json -e '
          . + {"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": strenv(HOOK), "timeout": 10}]}]}}
        ' list.json > $out
      '';

  tests =
    pkgs.runCommand "claude-code-deny-hook-bats"
      {
        nativeBuildInputs = [
          pkgs.bats
          pkgs.yq-go
          python
        ];
      }
      ''
        ${ownedToJson "${src}/tests/owned-dirs.fixture.yaml" "fixture.json"}
        cp -r ${src} src && chmod -R u+w src
        cd src/tests && bats .
        touch $out
      '';
}
