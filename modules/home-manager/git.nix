{ config, pkgs, lib, ... }:
let
  profile = config._module.specialArgs.profile;
  userName = profile.user.description;
  userEmail = profile.user.email;
  hostKeysDir = "${config.xdg.stateHome}/ssh-keys.d";
  stateHome = config.xdg.stateHome or "${config.home.homeDirectory}/.local/state";
in {
  imports = [ ./git.d/sops.nix ];

  home.packages = [ pkgs.github-cli ];

  programs.git = {
    enable = true;

    userName = userName;
    userEmail = userEmail;

    signing = {
      key = "${hostKeysDir}/github_signing.pub";
      format = "ssh";
      signByDefault = true;
    };

    extraConfig = {
      commit.verbose = true;
      credential.helper = if pkgs.stdenvNoCC.isDarwin then
        "osxkeychain"
      else
        "cache --timeout=1000000000";
      fetch.prune = true;
      http.sslVerify = true;
      http.sslCAInfo = "/etc/ssl/certs/ca-certificates.crt";
      init.defaultBranch = "main";
      pull.rebase = true;
      push.followTags = true;
      push.autoSetupRemote = true;
      rebase.autoStash = true;
    };

    aliases = {
      fix = "commit --amend --no-edit";
      ignore = "!gi() { curl -sL https://www.toptal.com/developers/gitignore/api/$@ ;}; gi";
      oops = "reset HEAD~1";
      sub = "submodule update --init --recursive";
    };

    delta = {
      enable = true;
      options = {
        side-by-side = true;
        line-numbers = true;
        light = true;
      };
    };

    difftastic.enable = false;

    includes = [
      { path = "config.d/signing"; }
      { path = "dotfiles"; }
      { path = "devcontainer"; }
      { path = "local"; }
    ];

    lfs.enable = true;
  };

  xdg.configFile = {
    "git" = {
      source = lib.fileset.toSource {
        root = ./git.d;
        fileset = lib.fileset.difference (lib.fileset.fromSource ./git.d)
          (lib.fileset.unions [
            (./git.d/config.d)
            (./git.d/sops)
            (./git.d/sops.d)
            (./git.d/sops.sh)
            (./git.d/sops.nix)
          ]);
      };
      recursive = true;
    };

    # Only the includeIf block here
    "git/config.d/signing" = {
      text = ''
        [includeIf "gitdir:**/*Hyland*/**"]
            path = "config.d/signing@hyland"
      '';
    };

    "git/config.d/signing@hyland" = {
      text = ''
        [user]
            email = stephane.lacoin@hyland.com
            signingkey = ${hostKeysDir}/github_signing_hyland.pub
      '';
    };

    "git/config.d/github_allowed_signers" = {
      text = ''
        stephane.lacoin@gmail.com namespaces="git" ${
          builtins.readFile "${stateHome}/ssh-keys.d/github_signing.pub"
        }
        stephane.lacoin@hyland.com namespaces="git" ${
          builtins.readFile "${stateHome}/ssh-keys.d/github_signing_hyland.pub"
        }
      '';
    };
  };
}
