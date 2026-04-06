{
  config,
  lib,
  pkgs,
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
  imports = [ ../common/ssh-paths.nix ];

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
      description = "Derived Lima/NixOS guest stanza configuration.";
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
              description = "Pinned key path (null -> defaultLimaKey).";
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

      # Tailnet info guarded
      tailnetName =
        if (hostProfile ? tailnet && hostProfile.tailnet ? name) then hostProfile.tailnet.name else null;
      tailnetDomain =
        if (hostProfile ? tailnet && hostProfile.tailnet ? domain) then
          hostProfile.tailnet.domain
        else
          null;
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

      defaultLimaKey =
        let
          home =
            if (config ? profile && config.profile ? user && config.profile.user ? home) then
              config.profile.user.home
            else
              "/Users/${userName}";
        in
        "${home}/.lima/_config/user";
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
      guestIdentity = if cfg.guest.identityFile != null then cfg.guest.identityFile else defaultLimaKey;
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
              guestHostKeySafetyConfig
              + optionalString (cfg.guest.extraConfig != null) cfg.guest.extraConfig;
          }
        else
          "";

      hostIdentityStanzas =
        optional cfg.hostIdentityDomains.enable {
          patterns =
            cfg.hostIdentityDomains.patterns
            ++ lib.optional (hostIdentityTailnetPattern != null) hostIdentityTailnetPattern;
          user = null;
          identityFile = hostIdentityFile;
          identitiesOnly = true;
          bypassAgent = false;
          extraConfig = ownedDomainHostKeyBypassConfig;
        };

      allExtraStanzas = hostIdentityStanzas ++ cfg.extraStanzas;

      extraText = concatStringsSep "\n" (map renderStanza allExtraStanzas);
    in
    {
      sshClient.hostIdentityDomains.identityRelativePath = lib.mkDefault (builtins.baseNameOf config.sshPaths.privKeyFile);

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
