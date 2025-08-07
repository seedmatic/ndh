{ self, lib, pkgs, config, ... }:
let
  useCustomConfig = config.linux-builder.useCustomConfig;
  qemu-pkgdb = self.packages.${pkgs.system}.qemu-pkgdb or pkgs.qemu;
in {
  options.linux-builder.useCustomConfig = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Enable custom config for linux-builder";
  };

  config = {
    # Ensure our shared SSH keys are used instead of generated ones
    system.activationScripts.setupLinuxBuilderKey = {
      text = ''
        # Replace any auto-generated linux-builder keys with our shared key
        if [ -f /etc/nix/linux-builder_ed25519 ]; then
          cp ${../../keys/builder_ed25519} /etc/nix/linux-builder_ed25519
          chmod 600 /etc/nix/linux-builder_ed25519
          chown root:wheel /etc/nix/linux-builder_ed25519
        fi
        if [ -f /etc/nix/linux-builder_ed25519.pub ]; then
          cp ${../../keys/builder_ed25519.pub} /etc/nix/linux-builder_ed25519.pub
          chmod 644 /etc/nix/linux-builder_ed25519.pub
          chown root:wheel /etc/nix/linux-builder_ed25519.pub
        fi
      '';
      deps = [ "etc" ];  # Run after /etc files are set up
    };
    
    nix.linux-builder = {
      enable = true;
      ephemeral = false;
      maxJobs = 4;
      supportedFeatures = [ "kvm" "benchmark" "big-parallel" ];
      # Don't automatically register as build machine if distributed builds are enabled
    } // lib.optionalAttrs (!config.services.crossHostBuilders.enable) {
      # Only add to build machines if distributed builds are disabled
      # (when distributed builds are enabled, they manage build machines exclusively)
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
              PasswordAuthentication = false;
              PermitRootLogin = "yes";
              PermitEmptyPasswords = false;
              PubkeyAuthentication = true;
            };
          };

          users.users.root.password = "root";
          users.users.builder = {
            isNormalUser = true;
            extraGroups = [ "wheel" ];
            # Add SSH key for remote builds
            openssh.authorizedKeys.keyFiles = [
              ../../keys/builder_ed25519.pub
            ];
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
