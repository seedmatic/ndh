# Publishes a port that another host serves on its loopback only, through an `ssh -N -L` held by systemd, for a fixed
# list of client addresses.
#
# Made for agents that bind loopback on purpose and serve whoever reaches their port: the list is the unit's own
# IPAddressDeny/IPAddressAllow (a cgroup eBPF filter on the ssh process), NOT the firewall, because the interfaces the
# clients arrive on (fabric-br, tailscale0) are trusted ones, accepted before networking.firewall.extraInputRules is
# read. The unit logs in with a key of its own, made here and never copied out; the target admits it with ONE
# restricted authorized_keys line (`from=<this host>,restrict,port-forwarding,permitopen="127.0.0.1:<port>"`), which
# the unit prints at start, so that key opens that one port and nothing else.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib) mkOption types;
  forwards = config.ndh.loopbackForward;
  stateDir = name: "/var/lib/loopback-forward/${name}";
  wildcard = a: a == "0.0.0.0" || a == "::" || a == "";
in
{
  options.ndh.loopbackForward = mkOption {
    default = { };
    description = "Ports another host serves on its loopback, published on one local address for a fixed list of clients.";
    type = types.attrsOf (
      types.submodule {
        options = {
          listen = {
            address = mkOption {
              type = types.str;
              description = "The one local address to listen on, never a wildcard.";
            };
            port = mkOption { type = types.port; };
          };
          target = {
            address = mkOption {
              type = types.str;
              description = "The target host as an IP: the unit's address filter names it, and no resolver is needed.";
            };
            user = mkOption { type = types.str; };
            hostKey = mkOption {
              type = types.str;
              description = "The target sshd's host public key, pinned.";
            };
            port = mkOption {
              type = types.port;
              description = "The port the target serves on its loopback.";
            };
          };
          from = mkOption {
            type = types.str;
            description = "This host's address as the target sees it: the `from=` of the target's authorized_keys line.";
          };
          clients = mkOption {
            type = types.nonEmptyListOf types.str;
            description = "The only source addresses admitted on the listening port.";
          };
        };
      }
    );
  };

  config = lib.mkIf (forwards != { }) {
    assertions = lib.mapAttrsToList (name: f: {
      assertion = !(wildcard f.listen.address);
      message = "ndh.loopbackForward.${name}: listen on one address, never a wildcard";
    }) forwards;

    users.users.loopback-forward = {
      isSystemUser = true;
      group = "loopback-forward";
      home = "/var/lib/loopback-forward";
    };
    users.groups.loopback-forward = { };

    systemd.services = lib.mapAttrs' (
      name: f:
      let
        dir = stateDir name;
        knownHosts = pkgs.writeText "loopback-forward-${name}-known-hosts" "${f.target.address} ${f.target.hostKey}\n";
        ensureKey = pkgs.writeShellScript "loopback-forward-${name}-key" ''
          if [ ! -e ${dir}/id_ed25519 ]; then
            ${pkgs.openssh}/bin/ssh-keygen -q -t ed25519 -N "" -C "loopback-forward-${name}@${config.networking.hostName}" -f ${dir}/id_ed25519
          fi
          echo "authorized_keys line for ${f.target.user}@${f.target.address}:" \
            "from=\"${f.from}\",restrict,port-forwarding,permitopen=\"127.0.0.1:${toString f.target.port}\" $(cat ${dir}/id_ed25519.pub)"
        '';
      in
      lib.nameValuePair "loopback-forward-${name}" {
        description = "Publish ${f.target.address}'s loopback :${toString f.target.port} on ${f.listen.address}:${toString f.listen.port}";
        wantedBy = [ "multi-user.target" ];
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ];
        serviceConfig = {
          User = "loopback-forward";
          Group = "loopback-forward";
          StateDirectory = "loopback-forward/${name}";
          StateDirectoryMode = "0700";
          ExecStartPre = ensureKey;
          ExecStart = lib.escapeShellArgs [
            "${pkgs.openssh}/bin/ssh"
            "-N"
            "-F"
            "none"
            "-i"
            "${dir}/id_ed25519"
            "-o"
            "IdentitiesOnly=yes"
            "-o"
            "IdentityAgent=none"
            "-o"
            "BatchMode=yes"
            "-o"
            "StrictHostKeyChecking=yes"
            "-o"
            "UserKnownHostsFile=${knownHosts}"
            "-o"
            "ExitOnForwardFailure=yes"
            "-o"
            "ServerAliveInterval=15"
            "-o"
            "ServerAliveCountMax=3"
            "-L"
            "${f.listen.address}:${toString f.listen.port}:127.0.0.1:${toString f.target.port}"
            "${f.target.user}@${f.target.address}"
          ];
          Restart = "always";
          RestartSec = 10;
          IPAddressDeny = "any";
          IPAddressAllow = [
            "127.0.0.1"
            f.target.address
          ]
          ++ f.clients;
          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          PrivateDevices = true;
          CapabilityBoundingSet = "";
          RestrictAddressFamilies = [
            "AF_INET"
            "AF_INET6"
            "AF_UNIX"
          ];
          SystemCallArchitectures = "native";
        };
      }
    ) forwards;
  };
}
