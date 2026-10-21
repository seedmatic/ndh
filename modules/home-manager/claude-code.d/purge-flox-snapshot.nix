# The Flox VS Code extension's snapshot purge, built once for the activation and for its check, so both run the same
# file. The keys are the ~/.claude.json purge's (purge-backend-env.nix), so the two purges cannot disagree.
{
  pkgs,
  nixBashTrampoline,
  loggerTag,
}:
let
  inherit (import ./purge-backend-env.nix { inherit pkgs nixBashTrampoline loggerTag; }) backendKeys;
  tools = pkgs.lib.makeBinPath [
    pkgs.sqlite
    pkgs.jq
    pkgs.python3
    pkgs.lsof
    pkgs.coreutils
  ];
  # The script's PATH is its tools alone; the check puts a stand-in lsof before them (`pathFirst`).
  build =
    trampoline: pathFirst:
    pkgs.writeShellScript "purge-flox-snapshot" ''
      export PATH=${pathFirst}${tools}
      ${builtins.readFile (
        pkgs.replaceVars ./purge-flox-snapshot.sh {
          nixBashTrampoline = trampoline;
          inherit loggerTag backendKeys;
        }
      )}
    '';
in
{
  script = build nixBashTrampoline "";

  # Two workspaces as the Bedrock days left them, and a clean one: the backend keys go from the closed one, the rest of
  # its snapshot and of its database stays, the one held open is not written, and the clean one is not rewritten.
  tests =
    let
      stub = pkgs.writeText "trampoline-stub.sh" ''
        ndh::logger:command:run() { shift; "$@"; }
      '';
    in
    pkgs.runCommand "claude-code-purge-flox-snapshot"
      {
        nativeBuildInputs = [
          pkgs.sqlite
          pkgs.jq
          pkgs.python3
          pkgs.coreutils
        ];
      }
      ''
        export HOME=$TMPDIR/home
        ws="$HOME/Library/Application Support/Code - Insiders/User/workspaceStorage"
        mkdir -p "$ws/closed" "$ws/held" "$ws/clean"
        snapshot='{"flox.autoActivate":true,"flox.previousActivatedEnv":{"PATH":"/a:/b","CLAUDE_CODE_USE_BEDROCK":"1","AWS_PROFILE":"p","ANTHROPIC_BASE_URL":"u","HOME":"/h"}}'
        for w in closed held; do
          sqlite3 "$ws/$w/state.vscdb" "create table ItemTable (key text unique on conflict replace, value blob);
            insert into ItemTable values ('flox.flox', '$snapshot'), ('other', 'kept');"
        done
        sqlite3 "$ws/clean/state.vscdb" "create table ItemTable (key text unique on conflict replace, value blob);
          insert into ItemTable values ('flox.flox', '{\"flox.previousActivatedEnv\":{\"PATH\":\"/a\"}}');"
        clean_sum="$(sha256sum "$ws/clean/state.vscdb")"

        # The `held` database is open in a process, as VS Code holds a workspace it has open.
        mkdir -p fakebin
        cat >fakebin/lsof <<EOF
        #!${pkgs.bash}/bin/bash
        case "\$*" in *"/held/"*) echo 1 ;; *) exit 1 ;; esac
        EOF
        chmod +x fakebin/lsof
        FAKEBIN="$PWD/fakebin" ${pkgs.bash}/bin/bash ${build stub "$FAKEBIN:"} 2>log

        env_of() { sqlite3 "$ws/$1/state.vscdb" "select value from ItemTable where key = 'flox.flox'" | jq -c '."flox.previousActivatedEnv"'; }
        [ "$(env_of closed)" = '{"PATH":"/a:/b","HOME":"/h"}' ] || { echo "FAIL: closed: $(env_of closed)" >&2; cat log >&2; exit 1; }
        [ "$(sqlite3 "$ws/closed/state.vscdb" "select value from ItemTable where key = 'other'")" = kept ] ||
          { echo "FAIL: the rest of the database changed" >&2; exit 1; }
        [ "$(sqlite3 "$ws/closed/state.vscdb" "select json_extract(value, '\$.\"flox.autoActivate\"') from ItemTable where key = 'flox.flox'")" = 1 ] ||
          { echo "FAIL: the rest of the snapshot changed" >&2; exit 1; }
        env_of held | grep -q CLAUDE_CODE_USE_BEDROCK || { echo "FAIL: a database held open was written" >&2; exit 1; }
        grep -q 'is open in VS Code' log || { echo "FAIL: the held database was not said" >&2; exit 1; }
        [ "$(sha256sum "$ws/clean/state.vscdb")" = "$clean_sum" ] || { echo "FAIL: a clean database was rewritten" >&2; exit 1; }
        touch $out
      '';
}
