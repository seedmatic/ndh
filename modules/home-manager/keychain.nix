{ ... }:
{
  programs.keychain = {
    enable = true;
    # Shell integration is handled centrally by modules/darwin/shell-keychain.nix,
    # which resolves runtime-managed key filenames from canonical /run secrets paths.
    enableZshIntegration = false;
    enableBashIntegration = false;
    enableNushellIntegration = false;
    enableFishIntegration = false;
  };
}
