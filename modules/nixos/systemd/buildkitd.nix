{
  config,
  pkgs,
  ndh,
  profile,
  ...
}:
let
  buildkitdToml = pkgs.writeText (ndh.store.prefixedName "buildkitd.toml") ''
    [worker.cdi]
    enabled = false

    [worker.containerd]
    enabled = true

    [frontend."dockerfile.v0"]
      enabled = true

    [frontend."gateway.v0"]
      enabled = true

      # If allowedRepositories is empty, all gateway sources are allowed.
      # Otherwise, only the listed repositories are allowed as a gateway source.
      # 
      # NOTE: Only the repository name (without tag) is compared.
      #
      # Example:
      # allowedRepositories = [ "docker-registry.wikimedia.org/repos/releng/blubber/buildkit" ]
      allowedRepositories = []
  '';
in
{
  imports = [ ./containerd.nix ];

  environment.etc."buildkit/buildkitd.toml".source = buildkitdToml;

  systemd.services.buildkitd = {
    description = "BuildKit Daemon";
    after = [
      "network.target"
      "containerd.service"
    ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.buildkit}/bin/buildkitd --config  /etc/buildkit/buildkitd.toml";
      Restart = "on-failure";
      User = "root";
    };
  };

  environment.systemPackages = with pkgs; [
    iptables
    runc
    nerdctl
    buildkit
    docker-buildx
  ];
}
