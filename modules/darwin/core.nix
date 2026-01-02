{
  self,
  lib,
  config,
  pkgs,
  ...
}:
let
  user = config.profile.user;
  userName = user.name;
  userDescription = user.description;
  userHome = user.home;
  userShell = user.shell;
in
{
  imports = [
    ./networking.nix
    ./cachix.nix
  ];

  # Enable automatic backup of conflicting files during activation
  environment.etc.backup.enable = true;

  # Provide a deterministic CA bundle for both user and daemon contexts
  # Use the canonical bundle path from pkgs.cacert and expose it at /etc/ssl/cert.pem for compatibility
  environment.etc."ssl/certs/ca-bundle.crt".source = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
  environment.etc."ssl/cert.pem".source = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";

  # Add darwin-rebuild to system packages for easy rebuilds
  environment.systemPackages = [
    self.inputs.darwin.packages.${pkgs.stdenv.hostPlatform.system}.darwin-rebuild
  ];

  # Belt-and-suspenders: ensure /run/current-system/sw/bin and /run/wrappers/bin (sudo wrapper)
  # are on PATH for login shells so darwin-rebuild and privileged tools are discoverable.
  environment.shellInit = lib.mkAfter ''
    prepend_path() {
      case ":$PATH:" in
        *":$1:"*) ;; # already present
        *) PATH="$1:$PATH" ;;
      esac
    }

    if [ -d /run/current-system/sw/bin ]; then
      # Order matters: wrappers first, then current-system, then default profile
      prepend_path /nix/var/nix/profiles/default/bin
      prepend_path /run/current-system/sw/bin
      prepend_path /run/wrappers/bin
      export PATH
    fi
  '';

  # Create symlink to host-specific flake for darwin-rebuild without --flake
  # Points to GitHub repo (develop branch) - no local clone needed
  # Use hostAlias if available (e.g., "alcide"), otherwise fall back to hostName
  environment.etc."nix-darwin/flake.nix".source =
    let
      hostDir =
        if
          config.profile.host ? hostAlias
          && config.profile.host.hostAlias != null
          && config.profile.host.hostAlias != ""
        then
          config.profile.host.hostAlias
        else
          config.networking.hostName;
      # Create a flake wrapper that references GitHub
      flakeContent = ''
        {
          description = "nix-darwin configuration for ${hostDir}";
          inputs.nix-darwin-home.url = "github:nxmatic/nix-darwin-home/develop?dir=hosts/${hostDir}";
          outputs = { nix-darwin-home, ... }: nix-darwin-home.outputs;
        }
      '';
    in
    pkgs.writeText "flake.nix" flakeContent;

  # auto manage nixbld users with nix darwin
  nix = {

    extraOptions = ''
      include /etc/nix/flox.conf
      include /etc/nix/custom.conf
      accept-flake-config = true
      always-allow-substitutes = true
      min-free = ${toString (10 * 1024 * 1024 * 1024)}  # 10 GB
      max-free = ${toString (20 * 1024 * 1024 * 1024)}  # 20 GB
      ssl-cert-file = /etc/ssl/cert.pem
      # Enable content-addressed derivations on Darwin for improved cache sharing and reduced churn of identical outputs.
      # Rollback: remove ca-derivations from this list and re-enable automatic optimise if desired.
      extra-experimental-features = nix-command flakes ca-derivations
      extra-platforms = aarch64-darwin
      # Add binary caches for substitution
      extra-trusted-substituters = https://cache.flakehub.com https://nxmatic.cachix.org
      extra-trusted-public-keys = cache.flakehub.com-1:t7S7JjLyIJJLv0a0BqXdFnJvr4P8pAB2Z9xN2lYZXvY= nxmatic.cachix.org-1:oWogvXdam3gTxKzPZCDqq8khybQpqRdNpQQrKG3r4xM= cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=
      # Increase download buffer size to prevent buffer full warnings
      download-buffer-size = 268435456  # 256 MB (was 64 MB default)
      # Enable pushing to nxmatic cache and use mirror for faster downloads
      # Alternative mirrors (uncomment one to use if cache.nixos.org is slow):
      # extra-substituters = https://cache.nixos.org https://nxmatic.cachix.org  # Official (default)
      # extra-substituters = https://mirrors.tuna.tsinghua.edu.cn/nix-channels/store https://nxmatic.cachix.org  # Tsinghua (China)
      # extra-substituters = https://mirrors.ustc.edu.cn/nix-channels/store https://nxmatic.cachix.org  # USTC (China)
      # extra-substituters = https://mirrors.bfsu.edu.cn/nix-channels/store https://nxmatic.cachix.org  # BFSU (China)
      extra-substituters = https://mirrors.tuna.tsinghua.edu.cn/nix-channels/store https://nxmatic.cachix.org
    '';

    # Configure NIX_PATH for legacy nix commands and <nixpkgs> imports
    nixPath = [
      "nixpkgs=${pkgs.path}"
      "darwin=${self.inputs.darwin}"
      "home-manager=${self.inputs.home-manager}"
    ];

    # Optimize the store
    # Disable automatic optimise for faster iterative builds; run `nix-store --optimise` manually when idle.
    optimise.automatic = false; # (@codebase) Was true. Manual optimise recommended.

    settings = {

      # Ensure SSL Cert file path located correctly
      ssl-cert-file = "/etc/ssl/cert.pem";

      # Expose CA bundle inside sandboxes for fetchers
      extra-sandbox-paths = [
        "/etc/ssl/cert.pem"
        "/etc/ssl/certs/ca-bundle.crt"
        "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
      ];

    };
  };
  nixpkgs.config = import ../common/nixpkgs-config.nix;

  nixpkgs.overlays = (config.nixpkgs.overlays or [ ]) ++ [
    (final: prev: {
      # Force tailscale to skip checks at the nixpkgs layer so builds never run tests
      tailscale = prev.tailscale.overrideAttrs (old: {
        doCheck = false;
        dontCheck = true;
        checkPhase = "echo skipping tailscale checkPhase";
        installCheckPhase = "echo skipping tailscale installCheckPhase";
        phases = builtins.filter (p: p != "checkPhase") (old.phases or [ ]);
      });
    })
  ];

  # launchd.user.envVariables = { XDG_RUNTIME_DIR = "${userHome}/.xdg"; };

  # Disable Google update services that trigger notifications
  services.disable-google-updaters.enable = true;

  # Used for backwards compatibility, please read the changelog before changing.
  # $ darwin-rebuild changelog
  system.stateVersion = 5;

  system.primaryUser = userName;

  users.users.${userName} = {
    home = userHome;
    description = userDescription;
    shell = userShell;
    uid = pkgs.lib.mkIf (user.uid != null) user.uid;
    # Primary group name already userName; set gid on group definition below
  };
  users.groups.${userName} = pkgs.lib.mkIf (user.gid != null) { gid = user.gid; };

}
