{
  config,
  ...
}: {
  programs.asdf-vm = {
    enable = true;
    launchd.agents.asdf-vm = {
      config = {
        ProgramArguments = [
          "${pkgs.zsh}"
          "${pkgs.asdf-vm}/bin/install-tool-versions"
        ];
        KeepAlive = {
          Crashed = true;
          SuccessfulExit = false;
        };
        ProcessType = "Background";
      };
    };
  };
}
