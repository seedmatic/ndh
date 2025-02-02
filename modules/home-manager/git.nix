{
  config,
  pkgs,
  lib,
  ...
}: {
  imports = [ ./git.d/sops.nix ];

  home.packages = [
    pkgs.github-cli
  ];

  programs.git = {
    enable = true;
    extraConfig = {
      commit.verbose = true;
      credential.helper =
        if pkgs.stdenvNoCC.isDarwin then "osxkeychain" else "cache --timeout=1000000000";
      fetch.prune = true;
      http.sslVerify = true;
      http.sslCAInfo = "/etc/ssl/certs/ca-certificates.crt";
      init.defaultBranch = "main";
      pull.rebase = true;
      push.followTags = true;
      push.autoSetupRemote = true;
      rebase.autoStash = true;
      gpg.format = "ssh";
      commit.gpgSign = true;
      gpg.ssh.allowedSignersFile = "${config.xdg.configFile.git.source}/git/allowed-signers";
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
      { path = "dotfiles"; }
      { path = "local"; }
    ];
    lfs.enable = true;
  };

  xdg.configFile = {
    "git" = {
      source = lib.fileset.toSource {
        root = ./git.d;
        fileset = lib.fileset.difference (lib.fileset.fromSource ./git.d) (
          lib.fileset.unions [
            (./git.d/sops)
            (./git.d/sops.d)
            (./git.d/sops.sh)
            (./git.d/sops.nix)
          ]
        );
      };
      recursive = true;
    };
  };

}
