{
  config,
  pkgs,
  ...
}: let

  user = config.profile.user;
  userName = user.name;
  userHome = user.home;

in {
  services.emacs = {
    enable = true;
    package = pkgs.emacs-nox;
  };

  launchd.user.agents.emacs.serviceConfig = {
    KeepAlive = true;
    UserName = "${userName}";
    EnvironmentVariables = {
      XDG_RUNTIME_DIR = "${userHome}/.xdg";
    };
  };
}
