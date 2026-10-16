# The `autoMode` block of ~/.claude/settings.json, built from rules.nix. Shared by the home-manager
# module, which writes it, and the flake's checks, which build it.
#
# The build fails on a block Claude Code would misread: an unknown section silently drops its rules,
# and a section without "$defaults" silently drops the built-in ones.
{ pkgs }:
pkgs.runCommand "claude-code-auto-mode.json"
  {
    nativeBuildInputs = [ pkgs.jq ];
    rules = builtins.toJSON (import ./rules.nix);
    passAsFile = [ "rules" ];
  }
  ''
    jq -e '
      (keys - ["environment", "allow", "soft_deny", "hard_deny"] | length == 0)
      and all(.[]; type == "array" and all(.[]; type == "string") and (map(select(. == "$defaults")) | length == 1))
    ' "$rulesPath" >/dev/null
    jq . "$rulesPath" > $out
  ''
