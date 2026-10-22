# The auto-mode classifier's rules. The operator's policy: everything passes except what security
# blocks (hard_deny) or wants confirmed (soft_deny). The managed deny list and the PreToolUse hooks
# are enforced whatever the classifier decides; these rules only spare the prompts around them.
{
  environment = [
    "$defaults"
    "A single developer's personal lab on a trusted home LAN: the operator owns every seedmatic and nxmatic repository, worktree and machine a session touches."
    "Repositories are external git worktrees under /Volumes/git-worktree-store/<org>/<repo>.d/<namespace>/<branch>, their bares under /Volumes/git-bare-store. Session scratch lives in .scratchpad.d/ directories (inside a repository, or ~/.claude/.scratchpad.d), the project memory in /Volumes/git-worktree-store/seedmatic/rke2lab.d/memory."
    "Local flakes are evaluated and built by revision (git+file://…?rev=<sha>). PreToolUse hooks refuse a working-tree evaluation (leak-guard), and a managed deny list with its own hook refuses the live-system verbs, host switches, binary publishing, keychain secrets, guard bypasses and forced pushes to develop or main, whatever this classifier decides."
    "Sessions can read the operator's employer's Confluence and Jira through the Atlassian plugin (Rovo). That content is corporate: it stays in private pages and private memory, never in a public repository."
    "The integration session assigns each session its branch, its worktree and the lead on it. Other sessions stacking their branches on that branch, or rebasing onto its heads, do not make the worktree a shared resource: the session holding the lead edits, builds and commits there as development work."
  ];

  allow = [
    "$defaults"
    "Read-only git queries in any of the operator's worktrees and bares, whoever holds the lead or stacks on the branch: git [-C <path>] status, log, diff, show, rev-parse, ls-files, blame, merge-base, for-each-ref, describe, shortlog, cat-file with -t, -s, -e or -p only, and only the listing forms of branch (no name argument: --list, -a, -r, -v, --contains, --merged), tag (-l, --list), worktree (list) and stash (list). Reading takes nothing; the index refresh of git status is a cache, not a change. The session's git config turns every sops textconv and smudge into cat (sops-git-env), so these queries print sops envelopes, never clear values; a command that resets that environment would run sops and print decrypted content. This covers a command only when EVERY part of it is such a query, or a read-only filter of its output (wc, grep, head, sort): a write chained to a query (`git -C x status && git commit`, `; git checkout`, `| xargs git …`) is judged on its own, as if the query were not there. It never covers an environment reset around the query (env -i, env -u, any GIT_* assignment, sudo, bash --noprofile --norc -c, zsh -f -c, exec env …), nor -c, --exec-path, --output, --ext-diff, --textconv, --filters, --batch, -O/--open-files-in-pager or --show-signature, which can run a program, decrypt or write a file. A repository-local core.fsmonitor, core.pager or diff.external would still run on these queries: a residual, since a session able to write .git/config can already run programs."
    "Any development work in the operator's repositories, worktrees, scratchpads and memory: reading, searching, editing, formatting, building, committing on a feature branch, and running test suites in every form (bats directly or through nix shell, flox activate or a scratchpad helper script; Maven with -DskipTests=false; nix build or nix flake check of a checks attribute by revision), unless a soft or hard block below applies."
    "Read-only inspection of the operator's machines and services: ssh to the lab hosts without sudo, read-only incus, kubectl and gh commands, pulumi preview, git fetch."
    "Writing in the sessions' own work areas, ~/.claude/.scratchpad.d/** and the memory worktree /Volumes/git-worktree-store/seedmatic/rke2lab.d/memory/**, by the file tools or by Bash (redirections, heredocs, tee, mkdir, cp, mv), and running the helper scripts kept there. The managed denies still apply inside them."
    "Running ndh-ops <tool>, as installed by ndh (on the PATH of the seat's profile) or run from a pushed ndh revision (nix run github:seedmatic/ndh/<sha>#ndh-ops -- <tool> …), while the operator's armed delegation names that tool, and ndh-ops status or disarm at any time: ndh-ops refuses the tool otherwise and logs every run."
    "Running ndh-claude-wake after a cold restart (the integration, or operations as its fallback): it reopens the sessions security engraved through VS Code's documented open?session= link, never runs claude itself, and the sessions it wakes stay idle until the integration messages them."
    "Switching the fleet through fleet-switch, as installed by ndh (on the PATH of the system profile) or run from a pushed ndh revision: operations' loop over the machines in their order, each switched by ndh-switch with its own refusals and logs. The operator delegated it to operations on 2026-10-17."
    "Switching a machine through ndh-switch <machine> <rev>, as installed by ndh (on the PATH of the system profile) or run from a pushed ndh revision (nix run github:seedmatic/ndh/<sha>#ndh-switch): it switches only a pushed revision of a known machine, and logs what it ran. The operator delegated these switches to the sessions on 2026-10-17."
  ];

  soft_deny = [
    "$defaults"
    "git push to any remote of any repository: pushes are gated by the integration session."
    "gh pr create, gh pr merge, gh api calls that write, and anything posted to an external service."
    "Any write tool of the Atlassian MCP: creating or updating a Confluence page, creating, editing or transitioning a Jira issue, adding a comment or a worklog. It acts on the employer's systems; its reads stay free."
    "sudo on a remote machine (a read-only ssh without sudo stays allowed)."
    "Downloading and running code: curl or wget piped into a shell, or running a script that was just fetched."
    "Writing Claude Code configuration under ~/.claude (settings, rules, skills) outside a git branch of the repository that manages it. ~/.claude/.scratchpad.d is scratch, not configuration."
    "rm -rf outside a scratch directory (a .scratchpad.d, a mktemp directory, /private/tmp). The deny-hook lets through, with no prompt, a removal of one exact path in the calling session's own area as security engraved it (owned-dirs.yaml)."
    "sops -d or sops decrypt piped into another command, when the decrypted values never reach the output."
  ];

  hard_deny = [
    "$defaults"
    "Putting corporate content read through Rovo (Confluence, Jira) into a public repository (rke2lab, ndh, nnh and the other seedmatic repos), a commit message, a document, or a memory note meant for a public port: summaries go to private pages or private memory only, and corporate pages are never quoted."
    "Printing or copying secret material: the keyhole keyring worktree and keyhole.git/.ssh; ~/.local/share/password-store/seedmatic and pass on any seedmatic/ entry; gpg -d and gpg --export-secret-*; private keys (~/.ssh/id_* other than .pub, ~/.config/sops/age/**, /var/lib/sops-nix/*.age), locally or over ssh; the macOS keychain's secrets (security find-generic-password -w, find-internet-password -w, dump-keychain), which hold the seedmatic subkey's passphrase; any sops -d or sops decrypt whose output reaches the transcript."
    "Evaluating or building a decrypted working tree: any nix command whose flake reference is a local path, '.', path: or git+file: without ?rev=."
    "Disabling a guard: git --no-verify; -c core.hooksPath=…; GIT_CONFIG_GLOBAL=/dev/null on a command that commits; changing a filter.sops-* setting or the global core.hooksPath; editing the managed settings, the session hooks, the deny-hook and leak-guard sources, or the deletion registry owned-dirs.yaml outside an ndh branch (the registry: only security's); writing disableAllHooks, or a hooks key, into any .claude/settings*.json (user, project or local scope)."
    "Rewriting public history: git push --force or --force-with-lease to develop or main, deleting a remote develop or main, changing a repository's visibility (gh repo edit --visibility)."
    "Running the operator's secret-reading tools, however invoked (by name, a store path, nix run of an attribute, a variable): ssh-keys-certify, ssh-keys-renew, attic-leaf-sign, incus-cluster-cert-renew, ndh-keyring, keys-reconcile window. The operator runs them; the one exception is ndh-ops on a delegation the operator armed."
    "Arming a delegation: ndh-ops arm, however invoked, and any write to /var/db/ndh-ops (the delegation file), by a tool, a redirection, sudo or a script."
    "Publishing binaries: cachix push, attic push, nix copy --to a cache. There is no public cache; a session never publishes."
    "The operator's live gestures: host switches by any other way than ndh-switch or fleet-switch (darwin-rebuild, nixos-rebuild, home-manager switch, an activate script); creating, editing or shadowing an ndh-switch or fleet-switch executable or alias outside an ndh branch; key generation, rotation and revocation (ssh-keygen into a key path, gpg --gen-key, --edit-key or --quick-*, sops rotate or updatekeys, ndh-keyring); live-system verbs (pulumi up, kubectl apply, incus mutations)."
  ];
}
