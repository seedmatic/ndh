{
  config,
  lib,
  pkgs,
  ndh,
  ...
}:
# The layer below the deny hook: no process on the seat reaches the corporate bare-metal, a python socket included,
# except the operator's ssh. One pf anchor, loaded at activation; /etc/pf.conf names it once and is otherwise
# macOS's own. The v4 rules come from the catalog, the v6 ones from sops (anchor.sh), so the home's /64 never
# enters the store. Design and corpus: 🛡️'s corp-egress-guard-design (2026-10-26).
let
  cfg = config.ndh.corpEgressGuard;
  netplan = ndh.context.catalog.netplan;
  rules = import ./corp-egress-guard.d/anchor.nix {
    lanAddress = netplan.lan.hosts.nikopol-vzhost.ip;
    linkAddress = netplan.baremetal.nikopol.vzHostAddress;
    user = config.system.primaryUser;
  };
  anchor = "io.seedmatic.ndh.corp-egress";
  anchorFile = "/etc/pf.anchors/${anchor}";
  secretPath = "/run/secrets/${anchor}.v6";
  order = config.ndh.darwin.postActivationOrder;
  loader = pkgs.writeShellApplication {
    name = "corp-egress-anchor";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gawk
      pkgs.gnugrep
    ];
    text = builtins.readFile ./corp-egress-guard.d/anchor.sh;
  };
in
{
  options.ndh.corpEgressGuard = {
    enable = lib.mkEnableOption "the seat's pf anchor toward the corporate bare-metal (enabling pf is the operator's gesture)";
    v6SopsKey = lib.mkOption {
      type = lib.types.str;
      default = "corp_egress/v6";
      description = "The .secrets key holding the v6 lines (home_prefix, router, link_local).";
    };
  };

  config = lib.mkIf cfg.enable {
    sops.secrets."${anchor}.v6" = {
      key = cfg.v6SopsKey;
      path = secretPath;
      owner = "root";
      mode = "0600";
    };

    # macOS's pf.conf, with the one anchor line added after Apple's own. pf reads it only when enabled. The hash is
    # Apple's stock file, measured on darwin.bioskop (macOS 27.0.1): nix-darwin moves it aside as
    # *.before-nix-darwin rather than abort on an unexpected /etc file.
    environment.etc."pf.conf" = {
      text = ''
        scrub-anchor "com.apple/*"
        nat-anchor "com.apple/*"
        rdr-anchor "com.apple/*"
        dummynet-anchor "com.apple/*"
        anchor "com.apple/*"
        load anchor "com.apple" from "/etc/pf.anchors/com.apple"
        anchor "${anchor}"
      '';
      knownSha256Hashes = [ "6fb5b260918922ca5ca4dfb296967d8edb9c12f2c043f26b64590758441d682d" ];
    };

    system.activationScripts.postActivation.text = lib.mkOrder order.corpEgressAnchor ''
      ${loader}/bin/corp-egress-anchor ${pkgs.writeText "${anchor}.v4" rules.text} ${secretPath} ${anchorFile} /sbin/pfctl ${anchor}
    '';
  };
}
