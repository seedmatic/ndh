{
  config,
  lib,
  pkgs,
  networkCatalog,
  ...
}:
let
  cfg = config.services.nfsDarwin;
  autoCfg = cfg.autofs;

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
    cp ${pkgs.replaceVars ./nfs-autofs.d/nfsd-reload.sh {
      activationLogger = ./common/activation-logger.sh;
    }} "$out"
    chmod +x "$out"
  '';
  autofsRefreshScript = pkgs.runCommand "autofs-refresh.sh" { } ''
    cp ${pkgs.replaceVars ./nfs-autofs.d/autofs-refresh.sh {
      activationLogger = ./common/activation-logger.sh;
    }} "$out"
    chmod +x "$out"
  '';
  syntheticReloadScript = pkgs.runCommand "synthetic-rebuild.sh" { } ''
    cp ${pkgs.replaceVars ./nfs-autofs.d/synthetic-rebuild.sh {
      activationLogger = ./common/activation-logger.sh;
    }} "$out"
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
        activationLogger = ./common/activation-logger.sh;
      }
    } "$out"
    chmod +x "$out"
  '';

  autoMasterLinkScript = pkgs.runCommand "auto-master-link.sh" { } ''
    cp ${pkgs.replaceVars ./nfs-autofs.d/auto-master-link.sh {
      activationLogger = ./common/activation-logger.sh;
    }} "$out"
    chmod +x "$out"
  '';

  autoMasterWriteScript = pkgs.runCommand "auto-master-write.sh" { } ''
    cp ${
      pkgs.replaceVars ./nfs-autofs.d/auto-master-write.sh {
        inherit autoMasterText;
        activationLogger = ./common/activation-logger.sh;
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
        activationLogger = ./common/activation-logger.sh;
      }
    } "$out"
    chmod +x "$out"
  '';

  exportsText =
    lib.concatStringsSep "\n" (
      lib.concatMap (
        path:
        map (
          net: "${path} ${cfg.exportOptions} -network ${net.network} -mask ${net.netmask}"
        ) allowedNetworks
      ) cfg.exports
    )
    + "\n";
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
      description = "Network names from profile.networkCatalog allowed to mount NFS exports.";
    };

    exportOptions = lib.mkOption {
      type = lib.types.str;
      default = "-alldirs";
      description = "Common export options applied to every shared path.";
    };

    exports = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "/private"
        "/private/var/lib/git"
        "/nix/store"
        "/Users"
      ];
      description = "Paths exported over NFS.";
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
    in
    {
      system.activationScripts.etc.text = lib.mkAfter ''
        cat > /etc/exports <<'EOF'
        ${exportsText}
        EOF
        ${autoMasterWriteBlock}${autoMasterLinkBlock}${syntheticEnsureBlock}${syntheticReloadBlock}${autofsNetBlock}${nfsdReloadScript}
      '';
    }
  );
}
