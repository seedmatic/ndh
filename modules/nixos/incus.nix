{
  config,
  pkgs,
  lib,
  ndh,
  ...
}:
let
  user = config.profile.user.name;
  hostProfile = config.profile.host;
  hasCatalogNetworks =
    config._module.specialArgs ? catalog && (config._module.specialArgs.catalog ? networks);
  catalogNetworks = if hasCatalogNetworks then config._module.specialArgs.catalog.networks else { };
  effectiveHostName =
    if (hostProfile ? hostAlias && hostProfile.hostAlias != null && hostProfile.hostAlias != "") then
      hostProfile.hostAlias
    else
      hostProfile.hostName;
  certHostLabels = lib.unique (
    lib.filter (name: name != null && name != "") [
      config.networking.hostName
      effectiveHostName
    ]
  );
  catalogDomainSuffixes =
    if hasCatalogNetworks then
      lib.filter (d: d != null && d != "") (
        map (network: network.domain or "") (builtins.attrValues catalogNetworks)
      )
    else
      [ ];
  certDomainSuffixes =
    # Keep `.local` as the mDNS suffix and derive LAN/Tailnet domains from catalog.
    lib.unique (
      map (
        domain:
        let
          normalized = lib.removePrefix "." domain;
        in
        if normalized == "" then "" else ".${normalized}"
      ) ([ ".local" ] ++ catalogDomainSuffixes)
    );
  incusServerCertNames = lib.unique (
    certHostLabels
    ++ (lib.concatMap (host: map (domain: "${host}${domain}") certDomainSuffixes) certHostLabels)
  );
  incusServerCertPrimaryName =
    if builtins.length certHostLabels > 0 then
      builtins.head certHostLabels
    else
      config.networking.hostName;
  ensureIncusServerCert = pkgs.runCommand (ndh.store.prefixedName "ensure-incus-server-cert.sh") { } ''
    cp ${
      pkgs.replaceVars ./incus.d/ensure-incus-server-cert.sh {
        bashTrampoline = "${../common/shell.d/nix-bash-trampoline.sh}";
        openssl = "${pkgs.openssl}/bin/openssl";
        incusServerCertPrimaryName = incusServerCertPrimaryName;
        incusServerCertNames = lib.concatMapStringsSep " " lib.escapeShellArg incusServerCertNames;
      }
    } $out
    chmod +x $out
  '';
  hostByteHex = lib.strings.toLower (
    builtins.substring 0 2 (builtins.hashString "sha256" effectiveHostName)
  );
  lanBridgeMac = "10:66:6a:4c:${hostByteHex}:fe";
  fixIncusSocketPerms = pkgs.runCommand (ndh.store.prefixedName "fix-incus-socket-perms.sh") { } ''
    cp ${pkgs.replaceVars ./incus.d/fix-incus-socket-perms.sh { }} $out
    chmod +x $out
  '';

in
{
  environment.systemPackages = with pkgs; [
    incus
    incus-compose
    skopeo
    debootstrap
    dpkg
    # Additional tools needed by debootstrap for proper Debian image building
    gnused
    gnugrep
    gnutar
    gawk
    util-linux
  ];

  users.users."${user}" = {
    extraGroups = [ "incus-admin" ];
  };

  virtualisation.incus = {
    enable = true;
    ui.enable = true;
    package = pkgs.incus;
    preseed = {
      config = {
        # Expose Incus HTTPS API for remote clients (e.g. Pulumi provider)
        "core.https_address" = "0.0.0.0:8443";
        # Trust tokens should be short-lived for remote bootstrap auth.
        "core.remote_token_expiry" = "10M";
      };
      # Canonical ownership split:
      # - lan-br is host-managed in this module (systemd-networkd)
      # - vmnet-br is Incus-managed by rke2lab bootstrap/Stage A (not preseeded here)
      # Keep this list empty to avoid conflicting controllers over vmnet-br.
      networks = [
      ];
      profiles = [
        {
          name = "default";
          description = "Instances on the bridged network";
          devices = {
            root = {
              path = "/";
              pool = "default";
              type = "disk";
            };
          };
        }
      ];
      storage_pools = [
        {
          name = "default";
          driver = "zfs";
          config = {
            source = "tank/nerd/incus";
          };
        }
      ];
    };
  };

  networking = {
    useNetworkd = false;
    networkmanager.enable = true;
    # NetworkManager should not manage vmlan0 - it's used as Incus lan-br bridge member
    networkmanager.unmanaged = [
      "interface-name:vmhost0"
      "interface-name:vmlan0"
      "interface-name:lan-br"
    ];
    # bridges.externalbr0.interfaces = [ "enp0s1" ];
    # interfaces.externalbr0.useDHCP = true; # Host gets an IP from LAN DHCP
    # interfaces.enp0s1.useDHCP =
    #   lib.mkForce false; # Physical NIC does not get its own IP
    firewall.trustedInterfaces = [
      "lan-br" # Allow DHCP/DNS/etc. on the Incus bridge
    ]; # Allow DHCP/DNS/etc. on bridge
    firewall.allowedTCPPorts = [
      8443 # Incus HTTPS API
    ];
    # interfaces.externalbr0.macAddress =
    #   "52:55:55:71:36:47"; # match your lima.yaml
  };

  # Create the lan-br bridge device
  systemd.network.netdevs."20-lan-br" = {
    netdevConfig = {
      Name = "lan-br";
      Kind = "bridge";
      MACAddress = lanBridgeMac;
    };
  };

  # Configure vmlan0 as bridge member
  systemd.network.networks."30-vmlan0" = {
    matchConfig.Name = "vmlan0";
    networkConfig = {
      Bridge = "lan-br";
      # Don't configure IP on the member interface
      DHCP = "no";
      IPv6AcceptRA = "no";
      LinkLocalAddressing = "no";
    };
  };

  # Configure the bridge itself with DHCP
  systemd.network.networks."40-lan-br" = {
    matchConfig.Name = "lan-br";
    linkConfig = {
      MACAddress = lanBridgeMac;
    };
    networkConfig = {
      DHCP = "yes";
      IPv6AcceptRA = "yes";
      LinkLocalAddressing = "no";
      DNS = "192.168.1.254";
      Domains = "lan";
    };
  };

  # Ensure lan-br picks up deterministic MAC via udev instead of polling loops (@codebase)
  systemd.network.links."10-lan-br" = {
    matchConfig.OriginalName = "lan-br";
    linkConfig = {
      MACAddress = lanBridgeMac;
      MACAddressPolicy = "none";
    };
  };

  systemd.tmpfiles.rules = [ "d /run/incus 0775 root incus-admin -" ];

  system.activationScripts.incusUserConfig = {
    text = builtins.readFile (
      pkgs.replaceVars ./incus.d/incus-user-config.sh {
        user = config.profile.user.name;
        home = config.profile.user.home;
        tailnetDomain =
          if
            config._module.specialArgs ? catalog && (config._module.specialArgs.catalog.networks ? tailnet)
          then
            lib.removePrefix "." config._module.specialArgs.catalog.networks.tailnet.domain
          else
            "tailnet.local";
        incusRemoteName = config.networking.hostName;
        # Canonical remote endpoint: use host label (no hard-coded domain suffix).
        # Domain-specific aliases are network policy concerns and should not be
        # baked into the default Incus remote address.
        incusRemoteAddress = "https://${config.networking.hostName}:8443";
        # Use the wrapped activation logger in the store
        bashTrampoline = "${../common/shell.d/nix-bash-trampoline.sh}";
        logger = config.nixBashLogger.script;
        loggerTag = "nixos.activationScripts.incusUserConfig";
      }
    );
  };

  systemd.services.incus = {
    restartTriggers = [ ensureIncusServerCert ];
    path = with pkgs; [ openssl ];
    serviceConfig = {
      ExecStartPre = [ "${ensureIncusServerCert}" ];
      ExecStartPost = [ "${fixIncusSocketPerms}" ];
    };
  };

}
