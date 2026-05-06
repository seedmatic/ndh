{
  self,
  lib,
  catalog,
  config,
  pkgs,
  ndh,
  ...
}:
let
  user = config.profile.user;
  userName = user.name;
  userDescription = user.description;
  userHome = user.home;
  userShell = user.shell;
  cacheCatalog = catalog.caches;
  flakehubPublicKeys =
    if cacheCatalog.flakehub ? publicKeys then
      cacheCatalog.flakehub.publicKeys
    else
      [ cacheCatalog.flakehub.publicKey ];
  flakehubPublicKeysJoined = lib.concatStringsSep " " flakehubPublicKeys;
in
{
  imports = [
    ./networking.nix
    ./cachix.nix
  ];

  # Enable automatic backup of conflicting files during activation
  environment.etc.backup.enable = true;

  # Provide a deterministic CA bundle for both user and daemon contexts.
  environment.etc."ssl/certs/ca-bundle.crt".source = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
  environment.etc."ssl/cert.pem".source = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
  environment.etc."gitconfig".text = ''
    [http]
      sslVerify = true
      sslCAInfo = /etc/ssl/cert.pem
  '';

  # Add darwin-rebuild to system packages for easy rebuilds
  environment.systemPackages = [
    self.inputs.darwin.packages.${pkgs.stdenv.hostPlatform.system}.darwin-rebuild
  ];

  # Export a canonical CA path for CLI tooling (including sudo -H flows)
  # to avoid OpenSSL/libcurl/git trust-store drift on Darwin.
  environment.variables = {
    SSL_CERT_FILE = "/etc/ssl/cert.pem";
    NIX_SSL_CERT_FILE = "/etc/ssl/cert.pem";
    GIT_SSL_CAINFO = "/etc/ssl/cert.pem";
    CURL_CA_BUNDLE = "/etc/ssl/cert.pem";
  };

  # Preserve TLS/CA environment variables through sudo so privileged nix/git
  # commands don't require repeating `sudo env ...` on Darwin.
  security.sudo.extraConfig = ''
    Defaults env_keep += "SSL_CERT_FILE NIX_SSL_CERT_FILE GIT_SSL_CAINFO CURL_CA_BUNDLE"
  '';

  # Belt-and-suspenders: ensure canonical Nix paths are on PATH for login shells
  # so darwin-rebuild and privileged tools are discoverable.
  environment.shellInit = lib.mkAfter ''
    prepend_path() {
      case ":$PATH:" in
        *":$1:"*) ;; # already present
        *) PATH="$1:$PATH" ;;
      esac
    }

    if [ -d /run/current-system/sw/bin ]; then
      # Order matters: wrappers (when present), then current-system, then default profile
      prepend_path /nix/var/nix/profiles/default/bin
      prepend_path /run/current-system/sw/bin
      if [ -d /run/wrappers/bin ]; then
        prepend_path /run/wrappers/bin
      fi
      export PATH
    fi
  '';

  # Create symlink to host-specific flake for darwin-rebuild without --flake
  # Point to the exact nix-darwin-home source used for this activation (store path),
  # so /etc/nix-darwin stays reproducible and does not depend on mutable git state.
  # Use hostAlias if available (e.g., "nikopol"), otherwise fall back to hostName
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
      # Create a flake wrapper that references the activated nix-darwin-home source
      flakeContent = ''
        {
          description = "nix-darwin configuration for ${hostDir}";
          inputs.nix-darwin-home.url = "path:${self.outPath}?dir=hosts/${hostDir}";
          outputs = { nix-darwin-home, ... }: nix-darwin-home.outputs;
        }
      '';
    in
    ndh.store.writeText "flake.nix" flakeContent;

  # auto manage nixbld users with nix darwin
  nix = {

    extraOptions = ''
      include /etc/nix/flox.conf
      include /etc/nix/nix-custom.conf
      accept-flake-config = true
      always-allow-substitutes = true
      min-free = ${toString (10 * 1024 * 1024 * 1024)}  # 10 GB
      max-free = ${toString (20 * 1024 * 1024 * 1024)}  # 20 GB
      ssl-cert-file = /etc/ssl/cert.pem
      # Enable content-addressed derivations on Darwin for improved cache sharing and reduced churn of identical outputs.
      # Rollback: remove ca-derivations from this list and re-enable automatic optimise if desired.
      extra-experimental-features = nix-command flakes ca-derivations configurable-impure-env
      extra-platforms = aarch64-darwin
      # Add binary caches for substitution
      extra-trusted-substituters = ${cacheCatalog.flakehub.substituter} ${cacheCatalog.nxmatic.substituter} ${cacheCatalog.flox.substituter}
      extra-trusted-public-keys = ${flakehubPublicKeysJoined} ${cacheCatalog.nxmatic.publicKey} ${cacheCatalog.nixos.publicKey} ${cacheCatalog.flox.publicKey}
      # Increase download buffer size to prevent buffer full warnings
      download-buffer-size = 268435456  # 256 MB (was 64 MB default)
      # Enable pushing to nxmatic cache and use mirror for faster downloads
      # Alternative mirrors (uncomment one to use if cache.nixos.org is slow):
      # extra-substituters = ${cacheCatalog.nixos.substituter} ${cacheCatalog.nxmatic.substituter}  # Official (default)
      # extra-substituters = ${cacheCatalog.tunaMirror.substituter} ${cacheCatalog.nxmatic.substituter}  # Tsinghua (China)
      # extra-substituters = https://mirrors.ustc.edu.cn/nix-channels/store ${cacheCatalog.nxmatic.substituter}  # USTC (China)
      # extra-substituters = https://mirrors.bfsu.edu.cn/nix-channels/store ${cacheCatalog.nxmatic.substituter}  # BFSU (China)
      extra-substituters = ${cacheCatalog.tunaMirror.substituter} ${cacheCatalog.nxmatic.substituter} ${cacheCatalog.flox.substituter}
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
        "/etc/gitconfig"
        "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
      ];

    };
  };
  nixpkgs.config = import ../.common.d/nixpkgs-config.nix;

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

  # Disable Spotlight indexing and clean stale indexes on mounted volumes
  services.disable-spotlight.enable = true;

  # Disable optional third-party background agents (Duet, Microsoft AutoUpdate)
  services.disable-unwanted-agents.enable = true;

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
