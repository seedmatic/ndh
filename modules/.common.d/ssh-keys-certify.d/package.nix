# ssh-keys-certify (see ssh-keys-certify.sh), built for the operator seat (6a: the seat signs every SSH certificate
# keys.yaml declares; the activation only installs them). One definition: the seat's module puts it in ndh-ops's
# tools, and the flake's app is that very package.
#   hostCertificates: the flake's fleetHostCertificates (names per machine).
{
  pkgs,
  ndh,
  hostCertificates,
}:
let
  inherit (pkgs) lib;
in
ndh.store.installBinScript "ssh-keys-certify" (
  pkgs.replaceVars ./ssh-keys-certify.sh {
    inherit (ndh.context) nixBashTrampoline;
    loggerTag = "ndh.ssh-keys-certify";
    keysJson = "${import ../keys-yaml.d/json-tool.nix { inherit pkgs; }}/bin/ndh-keys-json";
    hostNames = lib.concatStringsSep " " (
      lib.mapAttrsToList (
        machine: names: "${machine}=${lib.concatStringsSep "," names}"
      ) hostCertificates.names
    );
    sha256sum = "${pkgs.coreutils}/bin/sha256sum";
    sshKeygen = "${pkgs.openssh}/bin/ssh-keygen";
    toolPath = lib.makeBinPath (
      with pkgs;
      [
        coreutils
        diffutils
        gawk
        gnugrep
        gnused
        openssh
        sops
        yq-go
      ]
    );
  }
)
