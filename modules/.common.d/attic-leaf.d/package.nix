# attic-leaf-sign: certify each cache container's own TLS key under the TLS authority's current
# signing slot, install the leaf on its NixOS guest, verify (2a′; the hotfix rule: built by
# revision, run by the operator from the operator seat) — the model of incus-cluster-cert-renew.
# Everything that names a cache is fixed at evaluation: the caches are the NixOS guests that
# declare one (`ndh.atticCache`), each named by the catalog (`atticFqdn`) and reached by its
# guest's fabric FQDN; the keys.yaml it reads is the ENCRYPTED one of this revision. Imported by
# the flake's packages and apps, one definition.
# caches: [ { fqdn, via } ]. operatorIdentity: as for incus-cluster-cert-renew.
{
  pkgs,
  lib,
  caches,
  operatorIdentity,
}:
let
  paths = import ../../nixos/attic-cache.d/paths.nix;
  array = xs: "(" + lib.concatMapStringsSep " " lib.escapeShellArg xs + ")";
  tools = [
    pkgs.sops
    pkgs.yq-go
    pkgs.step-cli
    pkgs.openssl
    pkgs.coreutils
    pkgs.gnused
    pkgs.gnugrep
    pkgs.openssh
  ];
in
pkgs.writeShellApplication {
  name = "attic-leaf-sign";
  # SC2029: $remoteDir and $hostTls are expanded on the client ON PURPOSE, quoted into the remote
  # commands. SC2016: the single-quoted remote scripts (the tmpfs dir, the preflight) expand on the
  # GUEST, which is the point. SC1091: the logger library is sourced from the store, which
  # shellcheck cannot follow.
  excludeShellChecks = [
    "SC2029"
    "SC2016"
    "SC1091"
  ];
  runtimeInputs = tools;
  text = ''
    source ${../shell.d/logger.sh}
    toolPath=${lib.makeBinPath tools}
    loggerTag=ndh.attic-leaf-sign
    keysYaml=${lib.escapeShellArg "${../../home-manager/ssh.d/keys.yaml}"}
    authority=mammoth-skate-tls
    sshUser=${lib.escapeShellArg operatorIdentity.user}
    sshKey=${lib.escapeShellArg operatorIdentity.keyFile}
    sshCert=${lib.escapeShellArg operatorIdentity.certFile}
    days=365
    hostTls=${lib.escapeShellArg paths.hostTls}
    fqdns=${array (map (c: c.fqdn) caches)}
    vias=${array (map (c: c.via) caches)}
  ''
  + builtins.readFile ./attic-leaf-sign.sh;
}
