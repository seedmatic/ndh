{
  lib,
  config,
  pkgs,
  ...
}:
{
  programs.gpg = {
    enable = true;
    homedir = "${config.xdg.dataHome}/gnupg";
    settings = {
      use-agent = true;
    };
  };

  services.gpg-agent = {
    enable = true;
    defaultCacheTtl = 1800;
    enableSshSupport = false; # Disable SSH support to let keychain handle SSH keys
    extraConfig = ''
      allow-loopback-pinentry
    '';
  };

  # Import GPG keys from YAML on activation
  #  home.activation.importGpgKeys = lib.hm.dag.entryAfter ["writeBoundary"] ''
  #    KEYS_FILE="${config.home.homeDirectory}/.config/home-manager/gpg.d/keys.yaml"
  #    if [ -f "$KEYS_FILE" ]; then
  #      $DRY_RUN_CMD ${pkgs.bash}/bin/bash ${./gpg-import-keys-yaml.sh} \
  #        "${config.home.username}" \
  #        "$KEYS_FILE" || true
  #    fi
  #  '';
}
