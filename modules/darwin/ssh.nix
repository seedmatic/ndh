{ self, config, pkgs, lib,... }:
let
  profile = config.profile;
  profileName = profile.name;
  userHome = profile.user.home;
  userName = profile.user.name;

  userHM =
    self.darwinConfigurations."${profileName}".config.home-manager.users."${userName}";

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
    install -d -m 700 ~${userName}/.ssh/keys.d
    ${lib.escapeShellArg pkgs.rsync}/bin/rsync -avL \
      --chmod=u+w,go-r \
      --chown=${userName}:wheel \
      ${userHM.xdg.stateHome}/ssh-keys.d/ ${hostKeysDir}/ || true
  '';
}
