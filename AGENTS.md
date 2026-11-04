# Agentic delegation policy (ndh)

## Roles

- **Primary agent (`build`)** runs on `litellm/local-agent` (local 30B Qwen3-Coder). Its job is to understand intent, reason, plan, and answer. Keep context focused on decisions.
- **`local-worker`** (subagent, same 30B model) handles concrete, well-scoped execution: reading files, searching code, running shell commands, gathering precise output, small edits. Returns concise results (file/line references, command output).
- **`local-small`** (subagent, 1.5B) handles only trivial formatting, renaming, one-line lookups.

## Routing rules

Delegate to a subagent whenever the task requires **precise, concrete output** that would bloat the primary context:

1. Reading or searching files to extract specific facts → `local-worker`.
2. Running shell commands whose output is needed → `local-worker`.
3. Multi-step exploration of the repo → `local-worker`.
4. Trivial formatting/renaming/lookup → `local-small`.
5. Reasoning, design, synthesis, answering, final edits that depend on the above → primary agent.

Do not do exploratory tool calls in the primary agent when a subagent can return a compact answer.

The primary agent may only launch `local-worker` and `local-small` (enforced by permissions in `.opencode/agents/`).

## Cloud models

Cloud models (`opencode-go/*`) are opt-in and only for cases where local quality is insufficient. Do not route routine work to them.

## Shared worktree discipline

This repo uses the shared stack worktree model (see `shared-worktree` skill). Summary:

- One session writes at a time per worktree; reading takes nothing.
- A session does not write until the integration session has assigned it a branch AND given it the lead. Both, not either.
- A branch switch IS a lead transfer — announce it.
- `git add <paths>` explicitly — never `-A` or `.`.
- Check the branch before committing (`git rev-parse --abbrev-ref HEAD`).
- Trunk is `develop`; `main` only receives `--no-ff` merge-downs.
- Worktrees are external at `<repo>.d/<namespace>/<branch>` — never use `EnterWorktree`.

## Memory

Memory worktree is shared by every session; each session commits its explicit paths. Indexes stay shared.