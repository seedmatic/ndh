{
  pkgs,
  # Worktree-safe root marker: in split bare/worktree layouts `.git/config`
  # does not exist in the worktree because `.git` is a file.
  projectRootFile ? "flake.nix",
}:
{
  inherit projectRootFile;
  programs.nixfmt.enable = pkgs.lib.meta.availableOn pkgs.stdenv.buildPlatform pkgs.nixfmt-rfc-style.compiler;
  programs.nixfmt.package = pkgs.nixfmt-rfc-style;
  programs.shellcheck.enable = true;
  programs.deno.enable = false;
  programs.ruff.check = false;
  programs.ruff.format = false;
  settings.walk = "git";
  settings.formatter.shellcheck.options = [
    "-s"
    "bash"
    "-S"
    "error"
  ];
}
