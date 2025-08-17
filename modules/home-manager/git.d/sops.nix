{ config, lib, pkgs, ... }:

let
  sopsScript = pkgs.stdenvNoCC.mkDerivation {
    name = "sops-script";
    # replaceVars is the modern substituteAll (@codebase)
    src = pkgs.replaceVars ./sops.sh {
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
    includes = [ { path = "sops"; } ];
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
  # Plain include file has no placeholders; no need for replaceVars (@codebase)
  source = ./sops;
  };

  xdg.configFile."git/sops.sh" = {
    source = sopsScript;
  };

  xdg.configFile."git/sops.d/binary" = {
    source = pkgs.replaceVars ./sops.d/binary {
      sopsConfigHome = "${config.xdg.configHome}/git/sops.d";
    };
  };

  xdg.configFile."git/sops.d/yaml" = {
    source = pkgs.replaceVars ./sops.d/yaml {
      sopsConfigHome = "${config.xdg.configHome}/git/sops.d";
    };
  };

  xdg.configFile."git/sops.d/json" = {
    source = pkgs.replaceVars ./sops.d/json {
      sopsConfigHome = "${config.xdg.configHome}/git/sops.d";
    };
  };

  xdg.configFile."git/sops.d/xml" = {
    source = pkgs.replaceVars ./sops.d/xml {
      sopsConfigHome = "${config.xdg.configHome}/git/sops.d";
    };
  };

  xdg.configFile."git/sops.d/props" = {
    source = pkgs.replaceVars ./sops.d/props {
      sopsConfigHome = "${config.xdg.configHome}/git/sops.d";
    };
  };

  xdg.configFile."git/sops.d/csv" = {
    source = pkgs.replaceVars ./sops.d/csv {
      sopsConfigHome = "${config.xdg.configHome}/git/sops.d";
    };
  };

  xdg.configFile."git/sops.d/tsv" = {
    source = pkgs.replaceVars ./sops.d/tsv {
      sopsConfigHome = "${config.xdg.configHome}/git/sops.d";
    };
  };

  xdg.configFile."git/sops.d/base64" = {
    source = pkgs.replaceVars ./sops.d/base64 {
      sopsConfigHome = "${config.xdg.configHome}/git/sops.d";
    };
  };

  xdg.configFile."git/sops.d/uri" = {
    source = pkgs.replaceVars ./sops.d/uri {
      sopsConfigHome = "${config.xdg.configHome}/git/sops.d";
    };
  };

  xdg.configFile."git/sops.d/toml" = {
    source = pkgs.replaceVars ./sops.d/toml {
      sopsConfigHome = "${config.xdg.configHome}/git/sops.d";
    };
  };

  xdg.configFile."git/sops.d/lua" = {
    source = pkgs.replaceVars ./sops.d/lua {
      sopsConfigHome = "${config.xdg.configHome}/git/sops.d";
    };
  };
}
