# Podman remote configuration for macOS host (@codebase)
# This module configures the host to connect to the remote Podman engine in the Lima VM using containers.conf

{
  config,
  pkgs,
  lib,
  ...
}:

let
  dollar = "$";
  profileUser = config.profile.user.name; # Use profile-configured username

  generateContainersConf = pkgs.replaceVars ./podman-remote-client.d/generate-containers-conf.sh {
    inherit dollar profileUser;
    limaBin = "${pkgs.lima}/bin/limactl";
    yqBin = "${pkgs.yq-go}/bin/yq";
  };

  podmanRemoteSetupScript = pkgs.replaceVars ./podman-remote-client.d/podman-remote-setup.sh {
    inherit dollar profileUser generateContainersConf;
    dockerBin = "${pkgs.docker}/bin/docker";
    podmanBin = "${pkgs.podman}/bin/podman";
  };

  podman-remote-setup = pkgs.runCommand "podman-remote-setup" { } ''
    mkdir -p $out/bin
    cp ${podmanRemoteSetupScript} $out/bin/podman-remote-setup
    chmod +x $out/bin/podman-remote-setup
  '';

in
{
  # Add Podman and helper scripts to system packages
  # Note: No global environment variables set
  #       SSH configuration and Podman connections are managed through containers.conf
  environment.systemPackages = with pkgs; [
    buildah
    docker
    podman
    podman-compose
    podman-remote-setup
    podman-tui
    skopeo
  ];

}
