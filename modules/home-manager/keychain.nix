{ ... }:
{
  programs.keychain = {
    enable = true;
    enableZshIntegration = true;
    enableBashIntegration = true;
    enableNushellIntegration = true;
    enableFishIntegration = true;
    keys = [
      "~/.ssh/keys.d/host"
    ];
  };
}
