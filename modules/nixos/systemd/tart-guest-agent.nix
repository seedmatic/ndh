{
  config,
  lib,
  pkgs,
  ...
}:

let
  isTartProvider = config.ndh.vm.provider == "tart";
  cfg = config.ndh.vm.tart.guestAgent;
  resolvedPackage = if cfg.package != null then cfg.package else null;
  resolvedBinaryPath =
    if resolvedPackage != null then "${resolvedPackage}/bin/tart-guest-agent" else cfg.binaryPath;
  resolvedExecStart = lib.concatStringsSep " " ([ resolvedBinaryPath ] ++ cfg.arguments);
in
{
  options.ndh.vm.tart.guestAgent = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Enable Tart guest agent launch unit when ndh.vm.provider = tart.
      '';
    };

    package = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = lib.attrByPath [ "tart-guest-agent" ] null pkgs;
      description = ''
        Optional package that provides `bin/tart-guest-agent`.
        When set, this package is added to system packages and used as service ExecStart source.
      '';
    };

    binaryPath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Optional absolute path to a pre-provisioned `tart-guest-agent` binary.
        Used only when `package` is null.
      '';
    };

    arguments = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "--run-rpc" ];
      description = ''
        Arguments passed to `tart-guest-agent`.
        Default aligns with upstream Linux systemd packaging to enable `tart ip --resolver=agent` and RPC support.
      '';
    };
  };

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = !(isTartProvider && cfg.enable && resolvedBinaryPath == null);
          message = ''
            ndh.vm.tart.guestAgent.enable is true, but no guest-agent binary source is configured.
            Set ndh.vm.tart.guestAgent.package (preferred) or ndh.vm.tart.guestAgent.binaryPath.
          '';
        }
      ];
    }
    (lib.mkIf (isTartProvider && cfg.enable && resolvedPackage != null) {
      environment.systemPackages = [ resolvedPackage ];
    })
    (lib.mkIf (isTartProvider && cfg.enable && resolvedBinaryPath != null) {
    systemd.services.io-nxmatic-nix-darwin-home-tart-guestagent = {
      description = "Tart Guest Agent";
      wantedBy = [ "io-nxmatic-nix-darwin-home-contributed.target" ];
      after = [ "local-fs.target" ];

      unitConfig = {
        ConditionPathIsExecutable = resolvedBinaryPath;
      };

      serviceConfig = {
        Type = "simple";
        ExecStart = resolvedExecStart;
        Environment = [
          "PATH=/run/wrappers/bin:/run/current-system/sw/bin:/bin:/usr/bin"
        ];
        Restart = "on-failure";
        OOMPolicy = "continue";
        OOMScoreAdjust = "-500";
        User = "root";
      };
    };
    })
  ];
}
