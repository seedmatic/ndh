# incus-cluster-cert-renew: renew the Incus CLUSTER certificate under the TLS authority's current
# signing slot, ON THE KEY INCUS GENERATED (a CSR made on a member, signed on the operator seat), install it on
# every member, re-pin the operator seat's client, verify. Built by revision; run by the operator from the operator seat,
# and by bioskop's darwin activation with --activation. Everything that names the
# cluster is fixed at evaluation, from the catalog — the SAN set (the whole fleet's, sans.nix),
# the members, the names to verify — and the keys.yaml it reads is the ENCRYPTED one of this
# revision: nothing evaluates a working tree at run time. Imported by the flake's packages and
# apps, one definition.
# operatorIdentity: the ONE ssh identity the closure uses to reach a member — the OPERATOR
# principal's key, named by its role (rdp-host today; the `operator` key after the step-9 renewal
# changes this one argument): { user, keyFile, certFile }.
{
  pkgs,
  lib,
  netplan,
  operatorIdentity,
}:
let
  memberOf = host: netplan.baremetal.${host};
  hosts = lib.attrNames netplan.baremetal;
  # The member the certificate is filed under (its CN, and the operator seat client's remote name)
  # and installed through: the operator seat's guest. Members are reached over ssh by their fabric
  # FQDN (`nixos.<host>`), the name the operator seat resolves — not `<host>-nixos`.
  operatorSeatGuest = memberOf "bioskop";
  array = xs: "(" + lib.concatMapStringsSep " " lib.escapeShellArg xs + ")";
in
pkgs.writeShellApplication {
  name = "incus-cluster-cert-renew";
  # SC2029: $remoteDir is expanded on the client ON PURPOSE — it is the remote path the first ssh
  # returned, quoted into each later remote command. SC2016: the single-quoted remote scripts
  # (the tmpfs dir, the preflight) expand $(id -u) on the MEMBER, which is the point.
  # SC1091: the logger library is sourced from the store, which shellcheck cannot follow.
  excludeShellChecks = [
    "SC2029"
    "SC2016"
    "SC1091"
  ];
  runtimeInputs = [
    pkgs.sops
    pkgs.yq-go
    pkgs.step-cli
    pkgs.openssl
    pkgs.coreutils
    pkgs.gnused
    pkgs.gnugrep
    pkgs.incus.passthru.client
  ];
  text = ''
    source ${../shell.d/logger.sh}
    loggerTag=ndh.incus-cluster-cert-renew
    keysYaml=${lib.escapeShellArg "${../../home-manager/ssh.d/keys.yaml}"}
    authority=mammoth-skate-tls
    cn=${lib.escapeShellArg operatorSeatGuest.nixosHostname}
    via=${lib.escapeShellArg operatorSeatGuest.fabricFqdn}
    remote=${lib.escapeShellArg operatorSeatGuest.nixosHostname}
    sshUser=${lib.escapeShellArg operatorIdentity.user}
    sshKey=${lib.escapeShellArg operatorIdentity.keyFile}
    sshCert=${lib.escapeShellArg operatorIdentity.certFile}
    days=365
    sans=${array (import ./sans.nix { inherit lib netplan; })}
    members=${array (map (h: (memberOf h).fabricFqdn) hosts)}
    verifyNames=${
      array (
        lib.concatMap (h: [
          (memberOf h).nixosHostname
          (memberOf h).fabricFqdn
        ]) hosts
      )
    }
  ''
  + builtins.readFile ./incus-cluster-cert-renew.sh;
}
