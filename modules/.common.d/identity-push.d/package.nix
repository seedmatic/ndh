# ndh-identity-push (the seat) and ndh-identity-receive (the machine): bioskop gives a machine its
# identities, as a gesture of the operator (docs/ssh-keys-architecture.adoc). Everything that names the
# target is fixed at evaluation: a seat pushes to ITS guest only, at the inventory's address, through its
# own link. One definition, imported by the seat's and the machine's modules.
{ pkgs, lib }:
let
  # Where the machine's own host key is placed. Nothing serves it yet: sshd moves to it with S3.
  hostKeyFile = "/var/lib/ndh/host-key/ssh_host_ed25519_key";
  maxBytes = 8192;
in
{
  inherit hostKeyFile;

  # operatorIdentity: the ONE ssh identity used to reach the machine: { user, keyFile, certFile }.
  push =
    {
      seat,
      netplan,
      operatorIdentity,
    }:
    let
      bm = netplan.baremetal.${seat};
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
        machine=${lib.escapeShellArg bm.nixosHostname}
        address=${lib.escapeShellArg bm.hostAddress}
        localAddress=${lib.escapeShellArg bm.vzHostAddress}
        sshUser=${lib.escapeShellArg operatorIdentity.user}
        sshKey=${lib.escapeShellArg operatorIdentity.keyFile}
        sshCert=${lib.escapeShellArg operatorIdentity.certFile}
        maxBytes=${toString maxBytes}
        ttyIn=/dev/tty
        PATH="$PATH:/sbin:/usr/sbin" # route and ifconfig, the seat's own
      ''
      + builtins.readFile ./ndh-identity-push.sh;
    };

  receive =
    { machine, keyFile }:
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
        served=/etc/ssh/ssh_host_ed25519_key.pub
        owner=root:root
        maxBytes=${toString maxBytes}
      ''
      + builtins.readFile ./ndh-identity-receive.sh;
    };
}
