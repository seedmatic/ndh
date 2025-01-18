{
  inputs,
  config,
  lib,
  pkgs,
  ...
}: {

  nix.linux-builder = {
    enable = true;
    ephemeral = true;
    maxJobs = 4;
    config = { pkgs, ... }: let
      linuxPkgs = import <nixpkgs> { system = "aarch64-linux"; };
    in {
      config = {
        nix.channel.enable = lib.mkForce true;

        environment.systemPackages = [
          linuxPkgs.emacs-nox
          linuxPkgs.tailscale
        ];
        
        virtualisation = {
          darwin-builder = {
            diskSize = 200 * 1024;
            memorySize = 8 * 1024;
          };
          cores = 6;
        };

        services.tailscale = {
          enable = true;
          package = pkgs.tailscale;
        };

        services.openssh = {
          enable = true;
          settings = {
            PasswordAuthentication = true;
            PermitRootLogin = "yes";
          };
        };

        users.users.root.password = "root";
        users.users.builder = {
          isNormalUser = true;
          extraGroups = [ "wheel" ];
        };
        security.sudo.extraRules= [
          {  users = [ "%wheel" ];
             commands = [
               {
                 command = "ALL" ;
                 options= [ "NOPASSWD" ]; # "SETENV" # Adding the following could be a good idea
               }
             ];
          }
        ];

      };

    };
  };
}

