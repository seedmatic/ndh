{
  config,
  pkgs,
  lib,
  self,
  ...
}:
let
  specialArgs =
    if config ? _module && config._module ? specialArgs then config._module.specialArgs else { };
  nixBashTrampoline =
    if
      specialArgs ? ndh && specialArgs.ndh ? context && specialArgs.ndh.context ? nixBashTrampoline
    then
      "${specialArgs.ndh.context.nixBashTrampoline}"
    else
      "${self}/modules/.common.d/shell.d/nix-bash-trampoline.sh";
  profile = config._module.specialArgs.profile;
  userName = profile.user.name;
  userEmail = profile.email;
  sshPaths = config.sshPaths;
  # github-signing.pub / github-signing-hyland.pub are per-key public
  # files that the ssh-extract-keys split-exp routes to
  # `target_dir = "user"` → `secretsKeysDir`, alongside their private
  # counterparts.  Only authority CA pubs and certs land in
  # `authoritySecretsDir`; this used to point there and read missing
  # files.  See modules/home-manager/ssh-key.d/ssh-extract-keys.split-exp.yq.
  hostKeysDir = sshPaths.secretsKeysDir;
  signingKeysDir = sshPaths.secretsKeysDir;
  allowedSignersFile = "${config.xdg.configHome}/git/github_allowed_signers";
  systemCaBundle = config.home.sessionVariables.SSL_CERT_FILE;
  loggerTag = "home-manager.activationScripts.${userName}.generateAllowedSigners";
in
{
  imports = [
    ./git.d/sops.nix
    "${self}/modules/.common.d/ssh-paths.nix"
  ];

  home.packages = [ pkgs.github-cli ];

  programs.git = {
    enable = true;

    signing = {
      key = "${signingKeysDir}/github-signing.pub";
      format = "ssh";
      signByDefault = true;
    };

    settings = {
      user = {
        name = userName;
        email = userEmail;
      };

      commit.verbose = true;
      credential.helper =
        if pkgs.stdenvNoCC.isDarwin then "osxkeychain" else "cache --timeout=1000000000";
      fetch.prune = true;
      http.sslVerify = true;
      http.sslCAInfo = systemCaBundle;
      init.defaultBranch = "main";
      gh-get.root = "/var/lib/git";
      pull.rebase = true;
      push.followTags = true;
      push.autoSetupRemote = true;
      rebase.autoStash = true;
      gpg.ssh.allowedSignersFile = allowedSignersFile;

      alias = {
        fix = "commit --amend --no-edit";
        ignore = "!gi() { curl -sL https://www.toptal.com/developers/gitignore/api/$@ ;}; gi";
        oops = "reset HEAD~1";
        sub = "submodule update --init --recursive";
      };
    };

    includes = [
      { path = "config.d/signing"; }
      { path = "dotfiles"; }
      { path = "devcontainer"; }
      { path = "local"; }
    ];

    lfs.enable = true;
  };

  programs.delta = {
    enable = true;
    enableGitIntegration = true;
    options = {
      side-by-side = true;
      line-numbers = true;
      light = true;
    };
  };

  programs.difftastic.enable = false;

  xdg.configFile = {
    "git" = {
      source = lib.fileset.toSource {
        root = ./git.d;
        fileset = lib.fileset.difference (lib.fileset.fromSource ./git.d) (
          lib.fileset.unions [
            ./git.d/config.d
            ./git.d/sops
            ./git.d/sops.d
            ./git.d/sops.sh
            ./git.d/sops.nix
          ]
        );
      };
      recursive = true;
    };

    # Only the includeIf block here
    "git/config.d/signing" = {
      # Use absolute path so includeIf resolution is independent of current file location.
      text = ''
        [includeIf "gitdir/i:**/HylandExperience/**"]
          path = "${config.xdg.configHome}/git/config.d/signing@hyland"
        [includeIf "gitdir/i:**/HylandSoftware/**"]
          path = "${config.xdg.configHome}/git/config.d/signing@hyland"
        [includeIf "gitdir/i:**/HylandPlatformConfiguration/**"]
          path = "${config.xdg.configHome}/git/config.d/signing@hyland"
        [includeIf "gitdir/i:**/Alfresco/**"]
          path = "${config.xdg.configHome}/git/config.d/signing@hyland"
      '';
    };

    "git/config.d/signing@hyland" = {
      text = ''
        [user]
            email = stephane.lacoin@hyland.com
            signingkey = ${signingKeysDir}/github-signing-hyland.pub
      '';
    };
  };

  home.activation.generateAllowedSigners =
    let
      generateAllowedSignersScript = pkgs.replaceVars ./git.d/generate-allowed-signers.sh {
        nixBashTrampoline = nixBashTrampoline;
        allowedSignersFile = allowedSignersFile;
        hostKeysDir = hostKeysDir;
        loggerTag = loggerTag;
      };
    in
    lib.hm.dag.entryAfter [ "writeBoundary" "extractSSHKeys" ] ''
      ${pkgs.bash}/bin/bash ${generateAllowedSignersScript}
    '';
}
