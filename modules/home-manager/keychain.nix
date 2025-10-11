{...}: {
  programs.keychain = {
    enable = true;
    enableZshIntegration = true;
    enableBashIntegration = true;
    enableNushellIntegration = true;
    enableFishIntegration = true;
    keys = [
      "~/.lima/_config/user"
    ];
  };
}
