{
  config,
  lib,
  ndh,
  pkgs,
  worktreePath,
  ...
}:
# Dynamic SSH client configuration (@codebase)
# Recursion-safe design:
#  - Options have only static defaults (no references to config.* in defaults)
#  - All dynamic derivations (profile host / tailnet) happen in the config phase
#  - No other module should depend on config.sshClient.* for its OWN option defaults

let
  inherit (lib)
    mkIf
    mkOption
    types
    optionalString
    concatStringsSep
    optional
    optionalAttrs
    ;

in
{
  imports = [ (worktreePath.of "modules/.common.d/ssh-paths.nix") ];

  options.sshClient = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable ssh client configuration generation.";
    };

    baseConfig = mkOption {
      type = types.lines;
      default = ''
        Host *
          AddressFamily inet
          ServerAliveInterval 30
          ServerAliveCountMax 3
          ControlMaster auto
          ControlPersist 5m
          PreferredAuthentications publickey,keyboard-interactive
          StrictHostKeyChecking accept-new
        Include ssh_config.d/*.conf
        Include /etc/ssh/ssh_config.d/*.conf
      '';
      description = "Raw /etc/ssh/ssh_config base contents (may contain Include lines).";
    };

    guest = mkOption {
      description = "Derived VM/NixOS guest stanza configuration.";
      type = types.submodule (
        { ... }:
        {
          options = {
            enable = mkOption {
              type = types.bool;
              default = true;
              description = "Generate a derived guest stanza.";
            };
            useHostAlias = mkOption {
              type = types.bool;
              default = true;
              description = "Prefer profile.host.hostAlias over hostName when deriving base.";
            };
            nameSuffix = mkOption {
              type = types.str;
              default = "-nixos";
              description = "Suffix appended to base (e.g. bioskop -> bioskop-nixos).";
            };
            includeLocal = mkOption {
              type = types.bool;
              default = true;
              description = "Include .local pattern.";
            };
            includeTailnet = mkOption {
              type = types.bool;
              default = true;
              description = "Include tailnet FQDN pattern host.tailnetName.tailnetDomain.";
            };
            explicitPatterns = mkOption {
              type = types.listOf types.str;
              default = [ ];
              description = "If non-empty, override all derived patterns with this list.";
            };
            identityFile = mkOption {
              type = types.nullOr types.path;
              default = null;
              description = "Pinned key path for the guest stanza (null -> the host rdp-host key, which VM guests authorise).";
            };
            identitiesOnly = mkOption {
              type = types.bool;
              default = true;
              description = "Emit IdentitiesOnly yes for guest stanza.";
            };
            bypassAgent = mkOption {
              type = types.bool;
              default = false;
              description = "Emit IdentityAgent none for guest stanza.";
            };
            extraConfig = mkOption {
              type = types.nullOr types.lines;
              default = null;
              description = "Extra raw directives appended to the guest stanza.";
            };
          };
        }
      );
      default = { };
    };

    extraStanzas = mkOption {
      type = types.listOf (
        types.submodule (
          { ... }:
          {
            options = {
              patterns = mkOption {
                type = types.listOf types.str;
                description = "Host patterns (space joined).";
              };
              user = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = "User override.";
              };
              identityFile = mkOption {
                type = types.nullOr types.path;
                default = null;
                description = "Pinned key path.";
              };
              identitiesOnly = mkOption {
                type = types.bool;
                default = true;
                description = "Emit IdentitiesOnly yes if identityFile set.";
              };
              bypassAgent = mkOption {
                type = types.bool;
                default = false;
                description = "Emit IdentityAgent none.";
              };
              extraConfig = mkOption {
                type = types.nullOr types.lines;
                default = null;
                description = "Extra raw directives appended.";
              };
            };
          }
        )
      );
      default = [ ];
      description = "Additional explicit host stanzas.";
    };

    hostIdentityDomains = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Pin host identity key for selected domain patterns (avoids multi-key agent probing).";
      };

      patterns = mkOption {
        type = types.listOf types.str;
        # `*.lan` is left as a literal on purpose: this module's contract (top of
        # file) is that option defaults stay static — no specialArg/config reads —
        # to keep them recursion-safe.  Here `*.lan` reads as a generic host
        # pattern, not the managed LAN DNS fact, so it does not go through the
        # catalog like the resolver/networking modules do.
        default = [
          "*.host"
          "*.lan"
        ];
        description = "Host patterns that should use the profile host identity key by default.";
      };

      identityRelativePath = mkOption {
        type = types.str;
        default = "rdp-host";
        description = "Host identity private key path. By default this follows the basename of sshPaths.privKeyFile; relative paths are resolved against sshPaths.secretsKeysDir and absolute paths are used as-is.";
      };
    };
  };

  config = mkIf (pkgs.stdenv.isDarwin && config.sshClient.enable) (
    let
      cfg = config.sshClient;
      ndhContext = ndh.context;
      catalog = ndhContext.catalog;
      netplan = catalog.netplan or { };
      hostProfile = if (config ? profile && config.profile ? host) then config.profile.host else { };
      userProfile = if (config ? profile && config.profile ? user) then config.profile.user else { };
      userName = if (userProfile ? name && userProfile.name != null) then userProfile.name else "";

      # Determine base host component (may use alias)
      rawHost =
        if
          (
            cfg.guest.useHostAlias
            && (hostProfile ? hostAlias)
            && hostProfile.hostAlias != null
            && hostProfile.hostAlias != ""
          )
        then
          hostProfile.hostAlias
        else
          (
            if (hostProfile ? hostName && hostProfile.hostName != null && hostProfile.hostName != "") then
              hostProfile.hostName
            else
              "host"
          );
      baseHost = rawHost + cfg.guest.nameSuffix;

      # Tailnet info sourced from canonical netplan catalog
      tailnetName = if netplan ? tailnet && netplan.tailnet ? name then netplan.tailnet.name else null;
      tailnetDomain =
        if netplan ? tailnet && netplan.tailnet ? domain then netplan.tailnet.domain else null;
      normalizedTailnetDomain =
        if (tailnetDomain != null && tailnetDomain != "") then lib.removePrefix "." tailnetDomain else null;
      hostIdentityTailnetPattern =
        if (tailnetName != null && tailnetName != "" && normalizedTailnetDomain != null) then
          "*.${tailnetName}.${normalizedTailnetDomain}"
        else if (normalizedTailnetDomain != null) then
          "*.${normalizedTailnetDomain}"
        else
          null;
      tailnetFqdn =
        if (cfg.guest.includeTailnet && tailnetName != null && tailnetDomain != null) then
          "${baseHost}.${tailnetName}.${tailnetDomain}"
        else
          null;

      derivedPatterns =
        if (cfg.guest.explicitPatterns != [ ]) then
          cfg.guest.explicitPatterns
        else
          (
            [ baseHost ]
            ++ lib.optional cfg.guest.includeLocal "${baseHost}.local"
            ++ lib.optional (tailnetFqdn != null) tailnetFqdn
          );

      # Guest VMs (Lima and Tart both) authorise the same canonical
      # rdp-host key on `nxmatic` (via
      # `users.users.nxmatic.openssh.authorizedKeys.keys`); no other
      # key is accepted in the final configuration.  Use that key as
      # the guest-stanza default.
      #
      # Historical note: this used to point at
      # `${home}/.lima/_config/user` back when Lima was the sole VM
      # provider and Lima injected its own key during first-boot.
      # With the Tart-first layout that Lima key is never provisioned
      # on the guest, so the old default bricked `ssh
      # bioskop-nixos.local` — including nix-copy-closure invoked by
      # nixos-rebuild.
      defaultGuestIdentity = hostIdentityFile;
      guestHostKeySafetyConfig = ''
        UserKnownHostsFile /dev/null
        GlobalKnownHostsFile /dev/null
        StrictHostKeyChecking no
        CheckHostIP no
      '';
      ownedDomainHostKeyBypassConfig = ''
        UserKnownHostsFile /dev/null
        GlobalKnownHostsFile /dev/null
        StrictHostKeyChecking no
        CheckHostIP no
      '';
      guestIdentity =
        if cfg.guest.identityFile != null then cfg.guest.identityFile else defaultGuestIdentity;
      userHome =
        if (config ? profile && config.profile ? user && config.profile.user ? home) then
          config.profile.user.home
        else
          "/Users/${userName}";
      hostIdentityFile =
        if lib.hasPrefix "/" cfg.hostIdentityDomains.identityRelativePath then
          cfg.hostIdentityDomains.identityRelativePath
        else
          "${config.sshPaths.secretsKeysDir}/${cfg.hostIdentityDomains.identityRelativePath}";
      # `vzHost*` legacy bindings retired: they used to render a
      # system-wide `Host vz.<host>` block with a hardcoded
      # `HostName <host>-vz.lan`, but the .lan name was never
      # resolvable for either fleet host (bioskop has no separate VZ
      # host, nikopol's bare metal is on a corp network the bbox
      # can't reach).  The replacement is the single `vzhost.nikopol`
      # stanza in modules/home-manager/ssh-tailnet-hosts.nix, rendered
      # uniformly on every managed host — resolution + reachability
      # ride the per-baremetal split-DNS zone + advertised subnet route.
      # Leaving these symbols defined-but-empty keeps allExtraStanzas's
      # concat shape unchanged.

      renderStanza =
        st:
        let
          pats = concatStringsSep " " st.patterns;
        in
        ''
          Host ${pats}
        ''
        + optionalString (st.user != null) "  User ${st.user}\n"
        + optionalString (st.identityFile != null) "  IdentityFile ${st.identityFile}\n"
        + optionalString (st.identityFile != null && st.identitiesOnly) "  IdentitiesOnly yes\n"
        + optionalString st.bypassAgent "  IdentityAgent none\n"
        + optionalString (st.extraConfig != null) (st.extraConfig + "\n");

      guestStanza =
        if cfg.guest.enable then
          renderStanza {
            patterns = derivedPatterns;
            user = userName;
            identityFile = guestIdentity;
            identitiesOnly = cfg.guest.identitiesOnly;
            bypassAgent = cfg.guest.bypassAgent;
            extraConfig =
              guestHostKeySafetyConfig + optionalString (cfg.guest.extraConfig != null) cfg.guest.extraConfig;
          }
        else
          "";

      hostIdentityStanzas = optional cfg.hostIdentityDomains.enable {
        patterns =
          cfg.hostIdentityDomains.patterns
          ++ lib.optional (hostIdentityTailnetPattern != null) hostIdentityTailnetPattern;
        user = null;
        identityFile = hostIdentityFile;
        identitiesOnly = true;
        bypassAgent = false;
        extraConfig = ownedDomainHostKeyBypassConfig;
      };

      # Retired — see comment at vzHost* near line 280.
      vzHostStanzas = [ ];

      # Off-LAN SSH via the WAN port-forward table in the netplan catalog.
      # For every entry in `catalog.netplan.wan.portForwards` whose
      # `internalPort = 22`, emit a `ssh-proxy.<hostName>` alias pointing
      # at the WAN DDNS hostname on the matching external port — today
      # that yields `ssh-proxy.bioskop` → `mammoth-skate.duckdns.org:2222`.
      # The alias unlocks transparent screen-sharing over an SSH tunnel
      # from outside the LAN; adding a second forward in the catalog
      # (e.g. `ssh-proxy.nikopol`) requires no edit here.
      wan = netplan.wan or null;
      wanPortForwards = if wan != null && wan ? portForwards then wan.portForwards else { };
      wanProxyStanzas = lib.mapAttrsToList (externalPort: fwd: {
        patterns = [ "ssh-proxy.${fwd.hostName}" ];
        user = userName;
        identityFile = hostIdentityFile;
        identitiesOnly = true;
        bypassAgent = false;
        extraConfig = ''
          HostName ${wan.ddnsHostname}
          Port ${externalPort}
        '';
      }) (lib.filterAttrs (_: fwd: fwd.internalPort or 0 == 22) wanPortForwards);

      allExtraStanzas = hostIdentityStanzas ++ vzHostStanzas ++ wanProxyStanzas ++ cfg.extraStanzas;

      extraText = concatStringsSep "\n" (map renderStanza allExtraStanzas);
    in
    {
      sshClient.hostIdentityDomains.identityRelativePath = lib.mkDefault (
        builtins.baseNameOf config.sshPaths.privKeyFile
      );

      environment.etc."ssh/ssh_config".text = cfg.baseConfig + "\n";
      environment.etc."ssh/ssh_config.d/50-guest.conf" = mkIf (cfg.guest.enable) {
        text = "# Derived guest stanza\n" + guestStanza;
      };
      environment.etc."ssh/ssh_config.d/55-extra.conf" = mkIf (allExtraStanzas != [ ]) {
        text = "# Extra stanzas\n" + extraText + "\n";
      };
    }
  );
}
