{
  config,
  lib,
  pkgs,
  catalog,
  ...
}:
let
  networkCatalog = catalog.networks or { };
  shared = import ../common/nfs-shared.nix;
  # WARNING: Never let ZFS datasets or overlays mount or traverse /net (autofs)!
  # This prevents ZFS from hanging on network errors or unavailable NFS hosts.
  cfg = config.services.nfsDarwin;
  autoCfg = cfg.autofs;

  bool01 = b: if b then "1" else "0";

  pow = base: exp: lib.foldl' (acc: _: acc * base) 1 (lib.genList (_: null) exp);
  prefixToMask =
    prefix:
    let
      bitsForOctet =
        idx:
        let
          remaining = prefix - (idx * 8);
        in
        if remaining >= 8 then
          8
        else if remaining <= 0 then
          0
        else
          remaining;
      octetValue = bits: if bits <= 0 then 0 else 256 - pow 2 (8 - bits);
    in
    lib.concatStringsSep "." (
      map (idx: toString (octetValue (bitsForOctet idx))) (lib.genList (i: i) 4)
    );

  cidrToNetwork =
    cidr:
    let
      parts = lib.splitString "/" cidr;
      base = builtins.elemAt parts 0;
      prefix = if builtins.length parts > 1 then builtins.elemAt parts 1 else "32";
      prefixInt = builtins.fromJSON prefix;
    in
    {
      inherit base;
      network = base;
      netmask = prefixToMask prefixInt;
    };

  resolveAllowedNetworks =
    names:
    let
      requested = if names == [ ] then [ "lan" ] else names;
      resolveName =
        name:
        if builtins.hasAttr name networkCatalog then
          let
            entry = networkCatalog.${name};
            cidr = entry.cidr or null;
          in
          if cidr != null then
            cidrToNetwork cidr
          else
            lib.warn "Missing cidr for network in nfsDarwin.allowedNetworks: ${name}" null
        else
          lib.warn "Unknown network name in nfsDarwin.allowedNetworks: ${name}" null;
    in
    lib.filter (net: net != null) (map resolveName (lib.unique requested));

  allowedNetworks = resolveAllowedNetworks cfg.allowedNetworks;

  nfsdReloadScript = pkgs.runCommand "nfsd-reload.sh" { } ''
    cp ${
      pkgs.replaceVars ./nfs-autofs.d/nfsd-reload.sh {
        activationLogger = lib.attrByPath [
          "activation"
          "loggerScript"
        ] ../common/activation-logger.sh config;
      }
    } "$out"
    chmod +x "$out"
  '';
  autofsRefreshScript = pkgs.runCommand "autofs-refresh.sh" { } ''
    cp ${
      pkgs.replaceVars ./nfs-autofs.d/autofs-refresh.sh {
        activationLogger = lib.attrByPath [
          "activation"
          "loggerScript"
        ] ../common/activation-logger.sh config;
      }
    } "$out"
    chmod +x "$out"
  '';
  syntheticReloadScript = pkgs.runCommand "synthetic-rebuild.sh" { } ''
    cp ${
      pkgs.replaceVars ./nfs-autofs.d/synthetic-rebuild.sh {
        activationLogger = lib.attrByPath [
          "activation"
          "loggerScript"
        ] ../common/activation-logger.sh config;
      }
    } "$out"
    chmod +x "$out"
  '';

  isRootMount =
    path:
    let
      slashCount = lib.count (c: c == "/") (lib.stringToCharacters path);
    in
    (lib.hasPrefix "/" path) && (slashCount == 1);

  autoMasterLines = [
    "# Managed by nix-darwin (services.nfsDarwin.autofs)"
    "# See auto_master(5)"
    "#+auto_master\t# Use directory service (kept for compatibility)"
    "${autoCfg.mountPoint}\t${autoCfg.map}\t${autoCfg.options}"
    ("/home\tauto_home\t-nobrowse,hidefromfinder")
    ("/-\tauto_static\t-t14400")
  ];

  autoMasterText = lib.concatStringsSep "\n" autoMasterLines + "\n";

  syntheticEntries =
    let
      coercedExtra =
        if builtins.isList autoCfg.synthetic.extraEntries then
          autoCfg.synthetic.extraEntries
        else
          [ autoCfg.synthetic.extraEntries ];
    in
    lib.unique (autoCfg.synthetic.requiredEntries ++ autoCfg.synthetic.hostEntries ++ coercedExtra);

  syntheticText =
    if syntheticEntries == [ ] then "" else lib.concatStringsSep "\n" syntheticEntries + "\n";

  syntheticEnsureScript = pkgs.runCommand "synthetic-ensure.sh" { } ''
    cp ${
      pkgs.replaceVars ./nfs-autofs.d/synthetic-ensure.sh {
        inherit syntheticText;
        activationLogger = lib.attrByPath [
          "activation"
          "loggerScript"
        ] ../common/activation-logger.sh config;
      }
    } "$out"
    chmod +x "$out"
  '';

  autoMasterLinkScript = pkgs.runCommand "auto-master-link.sh" { } ''
    cp ${
      pkgs.replaceVars ./nfs-autofs.d/auto-master-link.sh {
        activationLogger = lib.attrByPath [
          "activation"
          "loggerScript"
        ] ../common/activation-logger.sh config;
      }
    } "$out"
    chmod +x "$out"
  '';

  autoMasterWriteScript = pkgs.runCommand "auto-master-write.sh" { } ''
    cp ${
      pkgs.replaceVars ./nfs-autofs.d/auto-master-write.sh {
        inherit autoMasterText;
        activationLogger = lib.attrByPath [
          "activation"
          "loggerScript"
        ] ../common/activation-logger.sh config;
      }
    } "$out"
    chmod +x "$out"
  '';

  autofsNetScript = pkgs.runCommand "autofs-net.sh" { } ''
    cp ${
      pkgs.replaceVars ./nfs-autofs.d/autofs-net.sh {
        mountPoint = lib.escapeShellArg autoCfg.mountPoint;
        map = lib.escapeShellArg autoCfg.map;
        options = lib.escapeShellArg autoCfg.options;
        manageAutoMaster = if autoCfg.manageAutoMaster then "1" else "0";
        autofsRefreshScript = autofsRefreshScript;
        activationLogger = lib.attrByPath [
          "activation"
          "loggerScript"
        ] ../common/activation-logger.sh config;
      }
    } "$out"
    chmod +x "$out"
  '';

  exportsText =
    let
      scopes =
        if cfg.clientScopes == [ ] then
          [
            {
              clients = "";
              options = cfg.exportOptions;
            }
          ]
        else
          cfg.clientScopes;

      translateOptions =
        optsStr:
        let
          opts = lib.splitString "," (if optsStr == "" then cfg.exportOptions else optsStr);
          flagFor = opt: if opt == "ro" then "-ro" else "";
          maprootFlag =
            if lib.any (o: o == "no_root_squash") opts then
              "-maproot=root"
            else if lib.any (o: o == "root_squash") opts then
              "-maproot=nobody"
            else
              "";
          baseFlags = lib.filter (f: f != "") (map flagFor opts);
        in
        lib.concatStringsSep " " (baseFlags ++ [ maprootFlag ]);

      cidrToNetworkMask =
        cidr:
        let
          parts = lib.splitString "/" cidr;
        in
        if builtins.length parts > 1 then
          {
            base = builtins.elemAt parts 0;
            mask = prefixToMask (builtins.fromJSON (builtins.elemAt parts 1));
          }
        else
          {
            base = cidr;
            mask = "";
          };

      scopeToLines =
        path: scope:
        let
          networks = lib.filter (s: s != "") (lib.splitString " " scope.clients);
          optFlags = translateOptions scope.options;
          baseFlags = lib.filter (s: s != "") ([
            "-alldirs"
            optFlags
          ]);
          renderNetwork =
            net:
            let
              nm = cidrToNetworkMask net;
              netFrag = if nm.mask == "" then "" else "-network ${nm.base} -mask ${nm.mask}";
              frags = lib.filter (s: s != "") (baseFlags ++ [ netFrag ]);
              line = "${path}\t${lib.concatStringsSep " " frags}";
            in
            line;
        in
        if networks == [ ] then
          [ "${path}\t${lib.concatStringsSep " " baseFlags}" ]
        else
          map renderNetwork networks;

      renderExport = path: lib.concatMap (scopeToLines path) scopes;
    in
    lib.concatStringsSep "\n" (lib.concatMap renderExport cfg.exports) + "\n";

  nfsConfText =
    if cfg.nfsConf.enable then
      ''
        nfs.client.is_mobile = ${bool01 cfg.nfsConf.isMobile}
        nfs.client.mount.options = ${cfg.nfsConf.mountOptions}
        nfs.client.mount_timeout = ${toString cfg.nfsConf.mountTimeout}
        nfs.client.mount_quick_timeout = ${toString cfg.nfsConf.mountQuickTimeout}
        nfs.client.initialdowndelay = ${toString cfg.nfsConf.initialDownDelay}
        nfs.client.nextdowndelay = ${toString cfg.nfsConf.nextDownDelay}
        nfs.client.uninterruptible_pagein = 0
        nfs.lockd.send_using_tcp = ${bool01 cfg.nfsConf.lockdUseTcp}
        nfs.lockd.send_using_mnt_transport = ${bool01 cfg.nfsConf.lockdUseMntTransport}
        nfs.server.mount.regular_files = ${bool01 cfg.nfsConf.allowRegularFileMounts}
        ${cfg.nfsConf.extraText}
      ''
    else
      "";
in
{
  options.services.nfsDarwin = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable NFS exports and autofs /net map on Darwin.";
    };

    allowedNetworks = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "lan"
        "tailnet"
      ];
      description = "Network names from catalog.networks allowed to mount NFS exports.";
    };

    exportOptions = lib.mkOption {
      type = lib.types.str;
      default = "-alldirs";
      description = "Common export options applied to every shared path.";
    };

    exports = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = shared.exportsDefault;
      description = "Paths exported over NFS.";
    };

    clientScopes = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            clients = lib.mkOption {
              type = lib.types.str;
              description = "Client CIDR or host spec.";
            };
            options = lib.mkOption {
              type = lib.types.str;
              default = "";
              description = "Extra export options for this client scope.";
            };
          };
        }
      );
      default = shared.clientScopesDefault;
      description = "Per-scope client/option pairs appended to each export.";
    };

    nfsConf = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Generate /etc/nfs.conf with mobile-friendly defaults.";
      };
      isMobile = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Treat this host as mobile for NFS client behavior.";
      };
      mountOptions = lib.mkOption {
        type = lib.types.str;
        default = shared.mountOptionsDefault;
        description = "Default NFS mount options applied by mount_nfs.";
      };
      mountTimeout = lib.mkOption {
        type = lib.types.int;
        default = shared.timeoutsDefault.mountTimeout;
        description = "Initial mount timeout (seconds).";
      };
      mountQuickTimeout = lib.mkOption {
        type = lib.types.int;
        default = shared.timeoutsDefault.mountQuickTimeout;
        description = "Quick mount timeout for automounts (seconds).";
      };
      initialDownDelay = lib.mkOption {
        type = lib.types.int;
        default = shared.timeoutsDefault.initialDownDelay;
        description = "Delay before first not-responding notice (seconds).";
      };
      nextDownDelay = lib.mkOption {
        type = lib.types.int;
        default = shared.timeoutsDefault.nextDownDelay;
        description = "Delay between not-responding notices (seconds).";
      };
      lockdUseTcp = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Prefer TCP for lockd.";
      };
      lockdUseMntTransport = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Use the mount transport for lockd when possible.";
      };
      allowRegularFileMounts = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Allow MOUNT requests for non-directory objects (macOS nfs.server.mount.regular_files).";
      };
      extraText = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Extra nfs.conf lines to append verbatim.";
      };
    };

    autofs = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Ensure /net uses the -hosts map for browsing NFS exports.";
      };

      mountPoint = lib.mkOption {
        type = lib.types.str;
        default = "/net";
        description = "Mount point used for the -hosts autofs map.";
      };

      map = lib.mkOption {
        type = lib.types.str;
        default = "-hosts";
        description = "Autofs map used for host-triggered NFS mounts.";
      };

      options = lib.mkOption {
        type = lib.types.str;
        default = "-nobrowse,nosuid";
        description = "Autofs options appended to the /net entry in /etc/auto_master.";
      };

      synthetic = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Manage /etc/synthetic.conf entries for root-level autofs mount points.";
        };
        requiredEntries = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [
            "nix"
            "run\tprivate/var/run"
          ];
          description = "Baseline synthetic.conf entries that are always included (e.g., /nix and /run symlink).";
          example = [
            "nix"
            "run\tprivate/var/run"
            "tmp\tprivate/var/tmp"
          ];
        };
        hostEntries = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "Host-specific synthetic.conf lines set in each host configuration (appended after required entries).";
        };
        extraEntries = lib.mkOption {
          type = lib.types.coercedTo lib.types.str (entry: [ entry ]) (lib.types.listOf lib.types.str);
          default = [ ];
          description = "Additional synthetic.conf entries to include (one path component per line).";
        };
      };

      manageAutoMaster = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "When true, replace /etc/auto_master with a generated map that includes /net.";
      };
    };
  };

  config = lib.mkIf cfg.enable (
    let
      autoMasterWriteBlock = lib.optionalString (autoCfg.enable && autoCfg.manageAutoMaster) ''
        ${autoMasterWriteScript}
      '';
      autoMasterLinkBlock = lib.optionalString (autoCfg.enable && autoCfg.manageAutoMaster) ''
        ${autoMasterLinkScript}
      '';
      syntheticEnsureBlock =
        lib.optionalString (autoCfg.enable && autoCfg.synthetic.enable && syntheticEntries != [ ])
          ''
            ${syntheticEnsureScript}
          '';
      syntheticReloadBlock =
        lib.optionalString (autoCfg.enable && autoCfg.synthetic.enable && syntheticEntries != [ ])
          ''
            ${syntheticReloadScript}
          '';
      autofsNetBlock = lib.optionalString autoCfg.enable ''
        ${autofsNetScript}
      '';
      nfsConfBlock = lib.optionalString cfg.nfsConf.enable ''
        cat > /etc/nfs.conf <<'EOF'
        ${nfsConfText}
        EOF
      '';
    in
    {
      system.activationScripts.etc.text = lib.mkAfter ''
        cat > /etc/exports <<'EOF'
        ${exportsText}
        EOF
        ${autoMasterWriteBlock}${autoMasterLinkBlock}${syntheticEnsureBlock}${syntheticReloadBlock}${autofsNetBlock}${nfsConfBlock}${nfsdReloadScript}
      '';
    }
  );
}
