{
  pkgs,
  # Worktree-safe root marker: in split bare/worktree layouts `.git/config`
  # does not exist in the worktree because `.git` is a file.
  projectRootFile ? "flake.nix",
}:
{
  inherit projectRootFile;
  programs.nixfmt.enable = pkgs.lib.meta.availableOn pkgs.stdenv.buildPlatform pkgs.nixfmt.compiler;
  programs.nixfmt.package = pkgs.nixfmt;
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

  # Validate keys.v2.yaml against its JSON Schema. check-jsonschema reads
  # YAML natively (via ruamel-yaml) so errors report YAML line/column back
  # at the source file rather than any intermediate conversion.
  # Not a formatter in the rewriting sense — it exits non-zero on invalid
  # input; treefmt surfaces the diagnostics and blocks the run.
  settings.formatter.keys-schema = {
    command = "${pkgs.check-jsonschema}/bin/check-jsonschema";
    options = [
      "--schemafile"
      "modules/home-manager/ssh.d/keys.schema.yaml"
    ];
    includes = [
      "modules/home-manager/ssh.d/keys.v2.yaml"
    ];
  };
}
