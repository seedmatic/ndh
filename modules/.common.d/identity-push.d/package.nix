# ndh-identity-push (the operator seat) and ndh-identity-receive (the machine): bioskop gives a machine its
# identities, as a gesture of the operator (docs/ssh-keys-architecture.adoc). Everything that names the
# targets is fixed at evaluation: the seat holding the keyring pushes to its guest over their /30, to the other
# metalspaces' machines at their home-LAN reservations (roles × keys ④), each through its own link, or to itself,
# with no network. One definition, imported by the operator seat's and the machine's modules.
{ pkgs, lib }:
let
  # Where the machine's own host key is placed; sshd serves it once the machine sets ndh.hostKey.own.
  hostKeyFile = "/var/lib/ndh/host-key/ssh_host_ed25519_key";
  # Where a NixOS guest's sshfs key is placed; its mounts use it once the guest sets ndh.sshfs.ownKey.
  sshfsKeyFile = "/var/lib/ndh/sshfs/id_ed25519";
  maxBytes = 8192;
in
{
  inherit hostKeyFile sshfsKeyFile;

  # operatorIdentity: the ONE ssh identity used to reach the machine: { user, keyFile, certFile }.
  # receive: the seat's own ndh-identity-receive, called by its store path so sudo's PATH does not choose it.
  push =
    {
      seat,
      netplan,
      operatorIdentity,
      receive,
    }:
    let
      bm = netplan.baremetal.${seat};
      lan = netplan.lan.hosts;
      # Its guest over the /30; every other metalspace's guest and darwin host on the home LAN.
      targets = [
        {
          name = bm.nixosHostname;
          kind = "nixos";
          address = bm.hostAddress;
          local = bm.vzHostAddress;
        }
      ]
      ++ lib.concatMap (
        host:
        let
          guest = netplan.baremetal.${host}.nixosHostname;
        in
        [
          {
            name = guest;
            kind = "nixos";
            address = lan.${guest}.ip;
            local = lan.${seat}.ip;
          }
          {
            name = host;
            kind = "darwin";
            address = lan.${host}.ip;
            local = lan.${seat}.ip;
          }
        ]
      ) (lib.filter (host: host != seat) (lib.attrNames netplan.baremetal));
      table =
        attr: lib.concatMapStringsSep " " (t: "[${t.name}]=${lib.escapeShellArg t.${attr}}") targets;
    in
    pkgs.writeShellApplication {
      name = "ndh-identity-push";
      runtimeInputs = [
        pkgs.age
        pkgs.coreutils
        pkgs.gawk
        pkgs.gnugrep
        pkgs.gnused
        pkgs.openssh
        pkgs.ssh-to-age
      ];
      text = ''
        seat=${lib.escapeShellArg seat}
        declare -A targetKind=(${table "kind"}) targetAddress=(${table "address"}) targetLocal=(${table "local"})
        machine="" kind="" address="" localAddress=""
        sshUser=${lib.escapeShellArg operatorIdentity.user}
        sshKey=${lib.escapeShellArg operatorIdentity.keyFile}
        sshCert=${lib.escapeShellArg operatorIdentity.certFile}
        maxBytes=${toString maxBytes}
        ttyIn=/dev/tty
        localSudo=/usr/bin/sudo
        localReceive=${receive}/bin/ndh-identity-receive
        PATH="$PATH:/sbin:/usr/sbin" # route and ifconfig, the operator seat's own
      ''
      + builtins.readFile ./ndh-identity-push.sh;
    };

  # served: what this machine's sshd serves, whose fingerprint the console prints for the push.
  # keyFile: the sops keyFile the age identity goes to, or "" for a machine whose frame carries the host key only.
  # sshfs: whether the frame carries the guest's sshfs key, placed at sshfsKeyFile (a guest that mounts sshfs).
  receive =
    {
      machine,
      keyFile,
      sshfs,
      served,
      owner,
    }:
    pkgs.writeShellApplication {
      name = "ndh-identity-receive";
      runtimeInputs = [
        pkgs.age
        pkgs.coreutils
        pkgs.openssh
      ];
      text = ''
        machine=${lib.escapeShellArg machine}
        keyFile=${lib.escapeShellArg keyFile}
        hostKeyFile=${lib.escapeShellArg hostKeyFile}
        sshfsKeyFile=${lib.escapeShellArg (lib.optionalString sshfs sshfsKeyFile)}
        served=${lib.escapeShellArg served}
        owner=${lib.escapeShellArg owner}
        maxBytes=${toString maxBytes}
      ''
      + builtins.readFile ./ndh-identity-receive.sh;
    };
}
