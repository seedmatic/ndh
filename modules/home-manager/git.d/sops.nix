{ config, lib, pkgs, ... }:

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
    source = pkgs.substituteAll {
      src = ./sops;
      sopsConfigHome = "${config.xdg.configHome}/git/sops.d";
    };
  };

  xdg.configFile."git/sops.sh" = {
    source = sopsScript;
  };

  xdg.configFile."git/sops.d/binary" = {
    source = pkgs.substituteAll {
      src = ./sops.d/binary;
      sopsConfigHome = "${config.xdg.configHome}/git/sops.d";
    };
  };

  xdg.configFile."git/sops.d/yaml" = {
    source = pkgs.substituteAll {
      src = ./sops.d/yaml;
      sopsConfigHome = "${config.xdg.configHome}/git/sops.d";
    };
  };

  xdg.configFile."git/sops.d/json" = {
    source = pkgs.substituteAll {
      src = ./sops.d/json;
      sopsConfigHome = "${config.xdg.configHome}/git/sops.d";
    };
  };

  xdg.configFile."git/sops.d/xml" = {
    source = pkgs.substituteAll {
      src = ./sops.d/xml;
      sopsConfigHome = "${config.xdg.configHome}/git/sops.d";
    };
  };

  xdg.configFile."git/sops.d/props" = {
    source = pkgs.substituteAll {
      src = ./sops.d/props;
      sopsConfigHome = "${config.xdg.configHome}/git/sops.d";
    };
  };

  xdg.configFile."git/sops.d/csv" = {
    source = pkgs.substituteAll {
      src = ./sops.d/csv;
      sopsConfigHome = "${config.xdg.configHome}/git/sops.d";
    };
  };

  xdg.configFile."git/sops.d/tsv" = {
    source = pkgs.substituteAll {
      src = ./sops.d/tsv;
      sopsConfigHome = "${config.xdg.configHome}/git/sops.d";
    };
  };

  xdg.configFile."git/sops.d/base64" = {
    source = pkgs.substituteAll {
      src = ./sops.d/base64;
      sopsConfigHome = "${config.xdg.configHome}/git/sops.d";
    };
  };

  xdg.configFile."git/sops.d/uri" = {
    source = pkgs.substituteAll {
      src = ./sops.d/uri;
      sopsConfigHome = "${config.xdg.configHome}/git/sops.d";
    };
  };

  xdg.configFile."git/sops.d/toml" = {
    source = pkgs.substituteAll {
      src = ./sops.d/toml;
      sopsConfigHome = "${config.xdg.configHome}/git/sops.d";
    };
  };

  xdg.configFile."git/sops.d/lua" = {
    source = pkgs.substituteAll {
      src = ./sops.d/lua;
      sopsConfigHome = "${config.xdg.configHome}/git/sops.d";
    };
  };
}
