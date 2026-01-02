{
  self,
  lib,
  pkgs,
  config,
  hostsCatalog ? { },
  ...
}:
let
  qemu-pkgdb = self.packages.${pkgs.system}.qemu-pkgdb or pkgs.qemu;

  keys = builtins.fromJSON (
    builtins.readFile (
      pkgs.runCommand "keys.json" { buildInputs = [ pkgs.yq-go ]; } ''
        yq -o=json '.' ${../home-manager/ssh.d/keys.yaml} > $out
      ''
    )
  );

  # Get current profile name
  currentProfile = config.profile.name;

  # Get SSH keys for current profile
  linuxBuilderCurrentPubKey = keys.profiles.${currentProfile}.linux-builder.public;
  linuxBuilderCurrentPrivKey = keys.profiles.${currentProfile}.linux-builder.private;

  # Also get keys for both profiles for VM authorized_keys
  linuxBuilderCommittedPubKey = keys.profiles.committed.linux-builder.public;
  linuxBuilderWorkPubKey = keys.profiles.work.linux-builder.public;
  # Pull builder catalog entries for this host (if present)
  hostName = config.profile.host.hostName;
  catalogEntries = if builtins.hasAttr hostName hostsCatalog then hostsCatalog.${hostName} else [ ];
  linuxBuilderEntries = lib.filter (
    entry: entry.builder != null && lib.elem "aarch64-linux" entry.builder.systems
  ) catalogEntries;
  selected = lib.head (linuxBuilderEntries ++ [ null ]);

in
{

  config = {
    nix.linux-builder = lib.mkIf (selected != null) {
      enable = true;
      ephemeral = true;
      workingDirectory = "/var/lib/linux-builder";
      maxJobs = selected.builder.maxJobs or 4;
      systems = selected.builder.systems or [ "aarch64-linux" ];
      protocol = selected.builder.protocol or "ssh-ng";
      speedFactor = selected.builder.speedFactor or 1;
      supportedFeatures =
        selected.builder.supportedFeatures or [
          "nixos-test"
          "benchmark"
          "big-parallel"
          "kvm"
        ];
      mandatoryFeatures = selected.builder.mandatoryFeatures or [ ];
      config = {
        virtualisation.darwin-builder.hostPort = selected.builder.hostPort or 31022;

        # Increase Linux builder VM disk size to handle large disk image builds
        virtualisation.diskSize = lib.mkForce (selected.builder.diskSize or (150 * 1024)); # 150 GB for building 64GB+ images

        # Use the same binary caches and settings as the Darwin configuration
        nix.settings = {
          trusted-substituters = [
            "https://cache.flakehub.com" # Determinate Systems FlakeHub cache
            "https://nxmatic.cachix.org" # nxmatic cache
          ];
          trusted-public-keys = [
            "cache.flakehub.com-1:t7S7JjLyIJJLv0a0BqXdFnJvr4P8pAB2Z9xN2lYZXvY=" # Determinate Systems key
            "nxmatic.cachix.org-1:oWogvXdam3gTxKzPZCDqq8khybQpqRdNpQQrKG3r4xM=" # nxmatic key
          ];

          # Additional substituters from flox.conf
          extra-trusted-substituters = [
            "https://cache.flakehub.com"
            "https://nxmatic.cachix.org"
          ];
          extra-trusted-public-keys = [
            "floxhub-1:0QOAlcobcEvq1mqEf4qAYCaWnTTOXpyoRv/PmqfSixM="
            "cache.flakehub.com-1:t7S7JjLyIJJLv0a0BqXdFnJvr4P8pAB2Z9xN2lYZXvY="
          ];

          # Connection and performance settings from flox.conf
          connect-timeout = lib.mkDefault 10;
          stalled-download-timeout = lib.mkDefault 30;

          # Buffer settings - increase download buffer to prevent buffer full warnings
          download-buffer-size = lib.mkDefault 268435456; # 256 MB (was 64 MB default)

          # Progress and logging settings
          log-lines = lib.mkDefault 50;

          # Storage management (use mkDefault to allow NixOS defaults to override)
          min-free = lib.mkDefault 128000000; # 128MB (from flox.conf)
          max-free = lib.mkDefault 1000000000; # 1GB (from flox.conf, but NixOS default 3GB will override)

          # Features
          # Enable content-addressed derivations inside the Linux builder VM to align with host and improve cache hit rate.
          experimental-features = [
            "nix-command"
            "flakes"
            "ca-derivations"
          ];
          accept-flake-config = true;
          always-allow-substitutes = true;
        };

        # Configure SSH daemon to also check our profile keys file
        services.openssh.authorizedKeysFiles = [
          "/var/keys/%u_ed25519.pub" # Original nix-darwin key location
          "/etc/ssh/builder_keys.pub" # Our profile keys location in /etc
          "%h/.ssh/authorized_keys" # Standard user location
          "/etc/ssh/authorized_keys.d/%u" # System location
        ];

        # Deploy profile SSH keys to the VM using NixOS environment.etc with mode
        environment.etc = {
          "ssh/builder_keys.pub" = {
            text = ''
              ssh-ed25519 ${linuxBuilderCommittedPubKey} committed-profile
              ssh-ed25519 ${linuxBuilderWorkPubKey} work-profile
            '';
            mode = "0644";
          };
        };
      };
    };

    # SSH keys are managed by the home-manager ssh-keys.nix module
    # Keys are deployed to ~/.ssh/keys.d/ with proper permissions
  };
}
