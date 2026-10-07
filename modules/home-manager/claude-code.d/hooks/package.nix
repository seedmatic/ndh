# The session hooks as a store directory, the `hooks` block that names them, and the bats run.
# Shared by the home-manager module, which writes the block into ~/.claude/settings.json, and the
# flake's checks. Each command carries its own PATH: a hook must not depend on the session's.
{ pkgs }:
let
  inherit (pkgs) lib;
  src = ./.;
  deps = with pkgs; [
    coreutils
    findutils
    gawk
    git
    gnugrep
    gnused
    jq
    yq-go
  ];

  dir = pkgs.runCommand "claude-code-session-hooks" { } ''
    mkdir -p $out
    cp ${src}/*.sh ${src}/memory-dir.bash $out/
    chmod +x $out/*.sh
  '';

  entry = name: timeout: statusMessage: {
    type = "command";
    command = "PATH=${lib.makeBinPath deps}:$PATH ${pkgs.bash}/bin/bash ${dir}/${name}";
    inherit timeout statusMessage;
  };
in
{
  hooks = {
    SessionStart = [
      {
        matcher = "*";
        hooks = [
          (entry "session-start-reminder.sh" 5 "Checking checkpoint draft status...")
          (entry "memory-guard.sh" 5 "Verifying memory wiring...")
        ];
      }
    ];
    PreCompact = [
      {
        matcher = "manual|auto";
        hooks = [ (entry "checkpoint-write.sh" 10 "Creating checkpoint before compaction...") ];
      }
    ];
    PostCompact = [
      {
        matcher = "manual|auto";
        hooks = [ (entry "checkpoint-gc.sh" 10 "Pruning orphaned checkpoints...") ];
      }
    ];
    SessionEnd = [
      {
        matcher = "*";
        hooks = [ (entry "memory-commit.sh" 20 "Committing memory...") ];
      }
    ];
  };

  tests =
    pkgs.runCommand "claude-code-session-hooks-bats"
      {
        nativeBuildInputs = [
          pkgs.bats
          pkgs.bash
        ]
        ++ deps;
      }
      ''
        cp -r ${src} src && chmod -R u+w src
        cd src/tests && HOME=$TMPDIR bats hooks.bats
        touch $out
      '';
}
