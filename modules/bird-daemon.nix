{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkOption types;

  cfg = config.services.bird;

  birdInterface = cfg.interface;

  getInterfaceIp = interface:
    pkgs.writeShellScript "get-${interface}-ip" ''
      ${pkgs.darwin.network_cmds}/bin/ifconfig ${interface} |
      ${pkgs.gnugrep}/bin/grep -w inet |
      ${pkgs.gawk}/bin/awk '{ print $2 }'
    '';

  routerId = builtins.readFile (pkgs.runCommand "get-router-id" {} ''
    ${getInterfaceIp birdInterface} > $out
  '');

  birdConfig = pkgs.writeText "bird.conf" ''
    log "/var/log/bird.log" { debug, trace, info, remote, warning, error, auth, fatal, bug };
    router id ${routerId};
    include "/etc/bird/protocol.d/*.conf";
  '';

  pfRules = pkgs.writeText "bird.rules" ''
    table <podman_networks> { 172.16.106.0/24, 10.88.0.0/16, 10.89.0.0/16, 10.90.0.0/15, 10.92.0.0/14, 10.96.0.0/11, 10.128.0.0/9 }
    pass quick on bridge100 proto udp from any to 224.0.0.9 port 520
    pass quick on bridge100 proto udp from (bridge100) to 224.0.0.9 port 520
    pass in quick on bridge100 from <podman_networks> to any flags S/SA keep state
    pass out quick on bridge100 from any to <podman_networks> flags S/SA keep state
  '';

  createUserScript = pkgs.writeScriptBin "create-daemon-user" ''
    #!${pkgs.bash}/bin/bash

    # Default values
    USERNAME="bird"
    GROUPNAME="bird"

    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
      case $1 in
        -u|--user)
          USERNAME="$2"
          shift 2
          ;;
        -g|--group)
          GROUPNAME="$2"
          shift 2
          ;;
        *)
          echo "Unknown option: $1"
          exit 1
          ;;
      esac
    done

    create_group_if_not_exists() {
      if ! dseditgroup -q -o read "$GROUPNAME" > /dev/null 2>&1; then
        dseditgroup -q -o create "$GROUPNAME"
        echo "Group '$GROUPNAME' created"
      else
        echo "Group '$GROUPNAME' already exists"
      fi
    }

    create_user_if_not_exists() {
      if ! dscl . -read "/Users/$USERNAME" > /dev/null 2>&1; then
        dscl . -create "/Users/$USERNAME"
        dscl . -create "/Users/$USERNAME" UserShell /sbin/nologin
        dscl . -create "/Users/$USERNAME" RealName "Daemon user for $USERNAME"
        dscl . -create "/Users/$USERNAME" NFSHomeDirectory /var/empty
        dscl . -create "/Users/$USERNAME" PrimaryGroupID $(dscl . -read "/Groups/$GROUPNAME" PrimaryGroupID | awk '{print $2}')
        dscl . -create "/Users/$USERNAME" Password "*"
        dscl . -create "/Users/$USERNAME" IsHidden 1
        dscl . -create "/Users/$USERNAME" GeneratedUID $(uuidgen)

        dseditgroup -o edit -a "$USERNAME" -t user everyone
        dseditgroup -o edit -a "$USERNAME" -t user localaccounts

        echo "User '$USERNAME' created"
      else
        echo "User '$USERNAME' already exists"
      fi
    }

    create_group_if_not_exists
    create_user_if_not_exists

    echo "Flushing Directory Services cache..."
    dscacheutil -flushcache
  '';

  reloadPfRules = pkgs.writeScriptBin "reload-pf-rules" ''
    #!${pkgs.bash}/bin/bash
    echo "Reloading pf rules..."
    sudo pfctl -f /etc/pf.conf
    echo "pf rules reloaded"
  '';
in {
  options = {
    services.bird = {
      enable = mkEnableOption "BIRD Internet Routing Daemon";
      interface = mkOption {
        type = types.str;
        default = "en0";
        description = "Network interface to use for BIRD";
      };
      protocols = mkOption {
        type = types.listOf (types.submodule {
          options = {
            name = mkOption {
              type = types.str;
              description = "Name of the protocol configuration file";
            };
            text = mkOption {
              type = types.lines;
              description = "Content of the protocol configuration";
            };
          };
        });
        default = [];
        description = "List of protocol configurations to include";
      };
      user = mkOption {
        type = types.str;
        default = "root";
        description = "User to run BIRD as";
      };
      group = mkOption {
        type = types.str;
        default = "daemon";
        description = "Group to run BIRD as";
      };
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = [pkgs.bird createUserScript reloadPfRules];

    environment.etc =
      {
        "bird/bird.conf".source = birdConfig;
        "pf.anchors/org.bird.daemon".source = pfRules;
      }
      // (builtins.listToAttrs (map (p: {
          name = "bird/protocol.d/${p.name}.conf";
          value = {source = pkgs.writeText "${p.name}.conf" p.text;};
        }) (
          if (builtins.any (p: p.name == "device") cfg.protocols)
          then cfg.protocols
          else
            [
              {
                name = "device";
                text = ''
                  protocol device device {
                    interface "${cfg.interface}";
                    scan time 30;
                  }
                '';
              }
            ]
            ++ cfg.protocols
        )));

    launchd.daemons.bird = {
      serviceConfig = {
        Label = "org.bird.daemon";
        ProgramArguments = [
          "${pkgs.bird}/bin/bird"
          "-f"
          "-c"
          "/etc/bird/bird.conf"
        ];
        RunAtLoad = true;
        KeepAlive = true;
        StandardOutPath = "/var/log/bird.log";
        StandardErrorPath = "/var/log/bird.error.log";
        WorkingDirectory = "/var/run/bird";
      };
    };

    system.activationScripts.postActivation.text = ''
      set -e  # Exit immediately if a command exits with a non-zero status
      echo "Starting BIRD configuration..."
      umask u=rwx,g=rx,o=rx
      echo "Umask set to $(umask)"
      echo "Creating BIRD user and group..."
      ${createUserScript}/bin/create-daemon-user --user ${cfg.user} --group ${cfg.group}
      echo "Creating BIRD run directory..."
      mkdir -p /var/run/bird
      chown -R ${cfg.user}:${cfg.group} /var/run/bird
      echo "Creating and setting permissions for log files..."
      touch /var/log/bird.log /var/log/bird.error.log
      chown ${cfg.user}:${cfg.group} /var/log/bird.log /var/log/bird.error.log
      chmod 644 /var/log/bird.log /var/log/bird.error.log
      echo "Listing contents of /etc/bird:"
      ls -alR /etc/bird
      echo "BIRD configuration completed"

      echo "Loading re-defined pf rules"
      pfctl -nf /etc/pf.anchors/org.bird.daemon
      pfctl -a org.bird.daemon -f /etc/pf.anchors/org.bird.daemon

      patch -u -N -t -b -l -p0 << 'EOF'
      --- /etc/pf.conf.orig	2024-10-16 18:03:10.647408657 +0200
      +++ /etc/pf.conf	2024-10-16 18:10:11.438461597 +0200
      @@ -21,5 +21,7 @@
       #
       scrub-anchor "com.apple/*"
       nat-anchor "com.apple/*"
       rdr-anchor "com.apple/*"
       dummynet-anchor "com.apple/*"
      +anchor "org.bird.daemon"
      +load anchor "org.bird.daemon" from "/etc/pf.anchors/org.bird.daemon"
      EOF
    '';
    system.defaults.alf.globalstate = 1;
    system.defaults.alf.allowsignedenabled = 1;
    system.defaults.alf.stealthenabled = 1;
  };
}
