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
    # sops-filter-check.sh shares the global git hooks' guard library: one source for both.
    cp ${../../git.d/hooks/lib-sops-filter-guard.sh} $out/lib-sops-filter-guard.sh
    # sops-git-env.sh names sops-clean-guard.sh by its own directory, as the clean filter's command.
    chmod +x $out/*.sh
    # notify.sh names osascript by its path, set here: the installed hook takes it from nothing else.
    substituteInPlace $out/notify.sh --replace-fail @osascript@ /usr/bin/osascript
  '';

  # Security's registry as installed beside the deny-hook: live-page.sh names an engraved session from it.
  registry = "${
    (import ../../../darwin/claude-code-managed.d/package.nix { inherit pkgs; }).hookDir
  }/owned-dirs.json";

  entry = name: timeout: statusMessage: {
    type = "command";
    command = "CLAUDE_SESSION_REGISTRY=${registry} PATH=${lib.makeBinPath deps}:$PATH ${pkgs.bash}/bin/bash ${dir}/${name}";
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
          (entry "live-page.sh" 5 "Registering with the integration...")
          (entry "sops-git-env.sh" 5 "Neutralising the sops git drivers for this session...")
          (entry "sops-filter-check.sh" 5 "Checking that no sops filter decrypts in this flake repository...")
        ];
      }
    ];
    PreToolUse = [
      {
        matcher = "Bash";
        hooks = [ (entry "leak-guard.sh" 5 "Checking for a working-tree evaluation...") ];
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
    # No matcher: every type is logged; the ones that wait on the operator also raise a macOS notification.
    Notification = [
      {
        hooks = [ (entry "notify.sh" 5 "Notifying the operator, and logging...") ];
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
        cp ${../../git.d/hooks/lib-sops-filter-guard.sh} src/lib-sops-filter-guard.sh
        cd src/tests && HOME=$TMPDIR bats hooks.bats
        # The installed notify.sh names /usr/bin/osascript, and no placeholder is left.
        grep -qF '"/usr/bin/osascript"' ${dir}/notify.sh
        if grep -q '@osascript@' ${dir}/notify.sh; then echo 'notify.sh: @osascript@ left unsubstituted' >&2; exit 1; fi
        touch $out
      '';
}
