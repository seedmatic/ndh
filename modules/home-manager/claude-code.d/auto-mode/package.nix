# The `autoMode` block of ~/.claude/settings.json, built from rules.nix. Shared by the home-manager
# module, which writes it, and the flake's checks, which build it.
#
# The build fails on a block Claude Code would misread: an unknown section silently drops its rules,
# and a section without "$defaults" silently drops the built-in ones.
{ pkgs }:
pkgs.runCommand "claude-code-auto-mode.json"
  {
    nativeBuildInputs = [ pkgs.yq-go ];
    rules = builtins.toJSON (import ./rules.nix);
    passAsFile = [ "rules" ];
  }
  ''
    # yq has no array subtraction nor all(gen; cond): the same test, measured equal on good and bad blocks.
    yq -p=json -o=json -e '
      ((keys | map(select(. != "environment" and . != "allow" and . != "soft_deny" and . != "hard_deny")) | length) == 0)
      and (map((tag == "!!seq") and ((map(tag == "!!str") | all)) and ((map(select(. == "$defaults")) | length) == 1)) | all)
    ' "$rulesPath" >/dev/null 2>&1
    yq -p=json -o=json . "$rulesPath" > $out
  ''
