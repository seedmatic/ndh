# modules/home-manager

## OVERVIEW
Home Manager modules for user environment: 133 files, 14 subdirs (shell, git, ssh, vscode, gnome, ...).

## STRUCTURE
feature.nix + .d assets. Key: default.d/, dotfiles/, ssh.d/, git.d/, shell.d/.

## WHERE TO LOOK
| Task | Location |
|------|----------|
| Shell | shell.d/ |
| Git | git.d/ (hooks, sops filters) |
| SSH | ssh.d/, ssh-key.d/, ssh-keys.d/ |
| Editor/terminal | vscode/, kitty.d/ |
| Dotfiles | dotfiles/ |
| GNOME | gnome/ |
| Flox config | flox-config.d/ |
| OMO patches | omo.d/, omo-patch.d/ |
| Incus remote | incus-remote.d/ |

## CONVENTIONS
- Uses hmSpecialArgs for keys.
- Profile-aware (bringup disables HM).
- Dotfiles managed under dotfiles/.
- Tests via bats in *.d/tests.

## ANTI-PATTERNS
- Don't enable HM in bringup mode.
- Don't duplicate shared logic; prefer modules/.common.d.

## NOTES
- 14 subdirs; dotfiles/ holds managed dotfiles.
- Profile-aware: HM disabled in bringup mode.
- HM config per user via catalog.
- Modules imported by hosts.
- See child AGENTS.md for git.d and ssh.d.
