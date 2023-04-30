{config, ...}: {
  environment.userLaunchAgents.asdf-vm-tool-versions-installer = {
    enable = self.programs.asdf-vm.enable;
    source = "${config.home.homeDirectory}/Library/LaunchAgents/asdf-vm-tool-versions-installer.plist";
  };
}
