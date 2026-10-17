# The auto-mode classifier's rules. The operator's policy: everything passes except what security
# blocks (hard_deny) or wants confirmed (soft_deny). The managed deny list and the PreToolUse hooks
# are enforced whatever the classifier decides; these rules only spare the prompts around them.
{
  environment = [
    "$defaults"
    "A single developer's personal lab on a trusted home LAN: the operator owns every seedmatic and nxmatic repository, worktree and machine a session touches."
    "Repositories are external git worktrees under /Volumes/git-worktree-store/<org>/<repo>.d/<namespace>/<branch>, their bares under /Volumes/git-bare-store. Session scratch lives in .scratchpad.d/ directories (inside a repository, or ~/.claude/.scratchpad.d), the project memory in /Volumes/git-worktree-store/seedmatic/rke2lab.d/memory."
    "Local flakes are evaluated and built by revision (git+file://…?rev=<sha>). PreToolUse hooks refuse a working-tree evaluation (leak-guard), and a managed deny list with its own hook refuses the live-system verbs, host switches, binary publishing, keychain secrets, guard bypasses and forced pushes to develop or main, whatever this classifier decides."
  ];

  allow = [
    "$defaults"
    "Any development work in the operator's repositories, worktrees, scratchpads and memory: reading, searching, editing, formatting, building, committing on a feature branch, and running test suites in every form (bats directly or through nix shell, flox activate or a scratchpad helper script; Maven with -DskipTests=false; nix build or nix flake check of a checks attribute by revision), unless a soft or hard block below applies."
    "Read-only inspection of the operator's machines and services: ssh to the lab hosts without sudo, read-only incus, kubectl and gh commands, pulumi preview, git fetch."
    "Writing in the sessions' own work areas, ~/.claude/.scratchpad.d/** and the memory worktree /Volumes/git-worktree-store/seedmatic/rke2lab.d/memory/**, by the file tools or by Bash (redirections, heredocs, tee, mkdir, cp, mv), and running the helper scripts kept there. The managed denies still apply inside them."
    "Switching a machine through ndh-switch <machine> <rev>, as installed by ndh (on the PATH of the system profile) or run from a pushed ndh revision (nix run github:seedmatic/ndh/<sha>#ndh-switch): it switches only a pushed revision of a known machine, and logs what it ran. The operator delegated these switches to the sessions on 2026-10-17."
  ];

  soft_deny = [
    "$defaults"
    "git push to any remote of any repository: pushes are gated by the integration session."
    "gh pr create, gh pr merge, gh api calls that write, and anything posted to an external service."
    "sudo on a remote machine (a read-only ssh without sudo stays allowed)."
    "Downloading and running code: curl or wget piped into a shell, or running a script that was just fetched."
    "Writing Claude Code configuration under ~/.claude (settings, rules, skills) outside a git branch of the repository that manages it. ~/.claude/.scratchpad.d is scratch, not configuration."
    "rm -rf outside a scratch directory (a .scratchpad.d, a mktemp directory, /private/tmp)."
    "sops -d or sops decrypt piped into another command, when the decrypted values never reach the output."
  ];

  hard_deny = [
    "$defaults"
    "Printing or copying secret material: the keyhole keyring worktree and keyhole.git/.ssh; ~/.local/share/password-store/seedmatic and pass on any seedmatic/ entry; gpg -d and gpg --export-secret-*; private keys (~/.ssh/id_* other than .pub, ~/.config/sops/age/**, /var/lib/sops-nix/*.age), locally or over ssh; the macOS keychain's secrets (security find-generic-password -w, find-internet-password -w, dump-keychain), which hold the seedmatic subkey's passphrase; any sops -d or sops decrypt whose output reaches the transcript."
    "Evaluating or building a decrypted working tree: any nix command whose flake reference is a local path, '.', path: or git+file: without ?rev=."
    "Disabling a guard: git --no-verify; -c core.hooksPath=…; GIT_CONFIG_GLOBAL=/dev/null on a command that commits; changing a filter.sops-* setting or the global core.hooksPath; editing the managed settings, the session hooks, or the deny-hook and leak-guard sources outside an ndh branch; writing disableAllHooks, or a hooks key, into any .claude/settings*.json (user, project or local scope)."
    "Rewriting public history: git push --force or --force-with-lease to develop or main, deleting a remote develop or main, changing a repository's visibility (gh repo edit --visibility)."
    "Publishing binaries: cachix push, attic push, nix copy --to a cache. Publication is the dedicated publishing user's job."
    "The operator's live gestures: host switches by any other way than ndh-switch (darwin-rebuild, nixos-rebuild, home-manager switch, an activate script); creating, editing or shadowing an ndh-switch executable or alias outside an ndh branch; key generation, rotation and revocation (ssh-keygen into a key path, gpg --gen-key, --edit-key or --quick-*, sops rotate or updatekeys, ndh-keyring); live-system verbs (pulumi up, kubectl apply, incus mutations)."
  ];
}
