{
  config,
  pkgs,
  ...
}: {
  
  services.emacs = {
    enable = true;
    package = pkgs.emacs-nox;
  };

  launchd.user.agents.emacs.serviceConfig = {
    KeepAlive = true;
	  UserName = "${config.user.name}";
  };
}
