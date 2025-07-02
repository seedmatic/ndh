{ inputs, lib, pkgs, config, ... }:
let
  useCustomConfig = config.linux-builder.useCustomConfig;
  qemu-pkgdb = inputs.self.packages.${pkgs.system}.qemu-pkgdb or pkgs.qemu;
in {
  options.linux-builder.useCustomConfig = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Enable custom config for linux-builder";
  };

  config = {
    nix.linux-builder = {
      enable = true;
      ephemeral = false;
      maxJobs = 4;
      supportedFeatures = [ "kvm" "benchmark" "big-parallel" ];
    } // lib.optionalAttrs useCustomConfig {
      config = { pkgs, ... }:
        let linuxPkgs = import <nixpkgs> { system = "aarch64-linux"; };
        in {
          nix.channel.enable = lib.mkForce true;

          virtualisation = {
            qemu.package = qemu-pkgdb; # May use the patched QEMU package
            darwin-builder = {
              diskSize = 200 * 1024;
              memorySize = 8 * 1024;
            };
            cores = 6;
          };

          services.openssh = {
            enable = true;
            settings = {
              PasswordAuthentication = true;
              PermitRootLogin = "yes";
              PermitEmptyPasswords = true;
            };
          };

          users.users.root.password = "root";
          users.users.builder = {
            isNormalUser = true;
            extraGroups = [ "wheel" ];
          };
          users.users.test = {
            isNormalUser = true;
            password = "";
          };

          security.sudo.extraRules = [{
            users = [ "%wheel" ];
            commands = [{
              command = "ALL";
              options = [
                "NOPASSWD"
              ]; # "SETENV" # Adding the following could be a good idea
            }];
          }];
        };
    };
  };
}
