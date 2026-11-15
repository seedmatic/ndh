{
  config,
  lib,
  pkgs,
  worktreePath,
  ...
}:

# Skills are now worktree-local under .agents/skills/ and are discovered by omo/senpi
# only when this repository is the active worktree. No global seeding into ~/.agents/skills.
{
  # Intentionally empty: keep the module importable for compatibility.
}
