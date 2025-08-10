{ self, config, pkgs, lib,... }:
let
  profile = config.profile;
  profileName = profile.name;
  userHome = profile.user.home;
  userName = profile.user.name;

  userHM = config.home-manager.users."${userName}";

  hostKeysDir = "${userHome}/.ssh/keys.d";
  hostKeyPrivateFile = "${hostKeysDir}/host";
  hostKeyPublicFile = "${hostKeysDir}/host-mammoth_skate-host-cert.pub";
  caPublicKeyFiles = "${hostKeysDir}/mammoth_skate-ca.pub";

  authorizedPrincipalsCommand =
    pkgs.writeScript "authorized-principals-command" ''
      #!${pkgs.bash}/bin/bash
      # Add your logic here to generate the list of allowed principals
      # For example, you could read from a file or query a database
      cat <<EOF
      staff
      admin
      EOF/
    '';
in {
  environment.systemPackages = with pkgs; [ rsync ];
  environment.etc = {
    "ssh/sshd_config.d/999-host-keys.conf" = {
      text = ''
        StrictModes no
        HostKey ${hostKeyPrivateFile}
        HostCertificate ${hostKeyPublicFile}
        TrustedUserCAKeys ${caPublicKeyFiles}
        AuthorizedPrincipalsCommand ${authorizedPrincipalsCommand} %u
        AuthorizedPrincipalsCommandUser _sshd
      '';
    };
  };

  system.activationScripts.postActivation.text = ''
    # Also install builder keys for nix daemon (root) access
    install -d -m 755 /etc/nix
    if [ -f "${userHome}/.ssh/keys.d/linux_builder" ]; then
      install -m 600 -o root -g wheel "${userHome}/.ssh/keys.d/linux_builder" /etc/nix/builder_ed25519_profile
    fi
    if [ -f "${userHome}/.ssh/keys.d/linux_builder.pub" ]; then
      install -m 644 -o root -g wheel "${userHome}/.ssh/keys.d/linux_builder.pub" /etc/nix/builder_ed25519_profile.pub
    fi
  '';
}
