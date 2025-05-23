{
  config,
  lib,
  pkgs,
  ...
}:

let
  sopsScript = pkgs.stdenvNoCC.mkDerivation {
    name = "sops-script";
    src = pkgs.substituteAll {
      src = ./sops.sh;
      sopsConfigHome = "${config.xdg.configHome}/git/sops.d";
    };
    sourceRoot = ".";
    unpackPhase = "true";
    installPhase = ''
      cp $src $out
      chmod +x $out
    '';
  };

  formats = [ "binary" "yaml" "json" "xml" "props" "csv" "tsv" "base64" "uri" "toml" "lua" ];
  filters = [ "textconv" "clean" "smudge" ];
in
{
  programs.git = {
    includes = [
      { path = "sops"; }
    ];
  };

  xdg.configFile."git/sops.d" = {
    source = pkgs.stdenvNoCC.mkDerivation {
      name = "sops-filtered-config";
      buildCommand = ''
        mkdir -p $out
        for ext in ${lib.concatStringsSep " " filters}; do
          for fmt in ${lib.concatStringsSep " " formats}; do
            ln -sf ${sopsScript} $out/$fmt-$ext
          done
        done
      '';
    };
    recursive = true;
  };

  xdg.configFile."git/sops" = {
    source = ./sops;
  };

  xdg.configFile."git/sops.sh" = {
    source = sopsScript;
  };
}
