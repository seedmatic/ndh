{
  self,
  config,
  pkgs,
  ...
}:

let
  profile = config.profile;
  profileName = profile.name;
  userHome = profile.user.home;
  userName = profile.user.name;

  userHM = self.darwinConfigurations."${profileName}".config.home-manager.users."${userName}";

  userNameVar = builtins.replaceStrings [ "." ] [ "_" ] userName;

  hostKeysDir = "${userHM.xdg.stateHome}/ssh-keys.d";
  hostKeyPrivateFile = "${hostKeysDir}/host";
  hostKeyPublicFile = "${hostKeysDir}/host-mammoth_skate-host-cert.pub";
  caPublicKeyFiles = "${hostKeysDir}/mammoth_skate-ca.pub";

   authorizedPrincipalsCommand = pkgs.writeScript "authorized-principals-command" ''
    #!${pkgs.bash}/bin/bash
    # Add your logic here to generate the list of allowed principals
    # For example, you could read from a file or query a database
    cat <<EOF
    staff
    admin
    EOF
  '';

in
{
  environment.etc = {
    "ssh/sshd_config.d/999-host-keys.conf" = {
      text = ''
        HostKey ${hostKeyPrivateFile}
        HostCertificate ${hostKeyPublicFile}
        TrustedUserCAKeys ${caPublicKeyFiles}
        AuthorizedPrincipalsCommand ${authorizedPrincipalsCommand} %u
        AuthorizedPrincipalsCommandUser _sshd
      '';
    };
  };
  
  system.activationScripts.postActivation.text = ''
      # shellcheck disable=SC2016
      
      : Set the permissions for the SSH keys
      find -L "${userHome}/.ssh/keys.d" -type f -print0 |
        xargs -0 -I{} echo 'file="$( realpath {} )"; chown ${userName} $file; chmod 400 $file' | 
        bash -x
      EoF
    '';
}
