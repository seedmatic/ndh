{ ... }:
{
  programs.keychain = {
    enable = true;
    enableZshIntegration = true;
    enableBashIntegration = true;
    enableNushellIntegration = true;
    enableFishIntegration = true;
    keys = [
      "~/.local/state/ssh-keys.d/host"
    ];
  };
}
