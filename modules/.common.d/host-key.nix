# Whether a machine serves its OWN host key, placed by ndh-identity-push, or the shared rdp-host (roles × keys
# S3a). One declaration for NixOS guests and operator seats; the platform openssh modules read it.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ndh.hostKey;
  machine = config.networking.hostName;
in
{
  options.ndh.hostKey = {
    own = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Serve this machine's own host key, at `ndh.hostKey.file`, with the certificate keys.yaml records
        for `host-<hostName>`. Turned on only once the key is placed: sshd serves no other, so switching
        before it is there stops sshd.
      '';
    };

    file = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = (import ./identity-push.d/package.nix { inherit pkgs lib; }).hostKeyFile;
      description = "Where ndh-identity-push places the machine's own host key.";
    };

    # Not read-only only so the eval checks can give a test configuration a certificate that keys.yaml
    # does not hold.
    certificate = lib.mkOption {
      type = lib.types.str;
      internal = true;
      default = import ./host-key.d/certificate.nix { inherit lib; } config.ndh.keysYaml.keys machine;
      description = "The ssh-host certificate recorded in keys.yaml for host-<hostName>; refuses to evaluate without one.";
    };

    certificateFile = lib.mkOption {
      type = lib.types.path;
      readOnly = true;
      default = pkgs.writeText "host-${machine}-cert.pub" "${cfg.certificate}\n";
      description = "HostCertificate: a store file, as the certificate is public.";
    };

    check = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = pkgs.writeShellScript "ndh-host-key-check" ''
        [[ -s ${cfg.file} ]] && exit 0
        echo "ERROR: ${cfg.file} is missing, and ${machine}'s sshd serves no other host key (ndh.hostKey.own)." >&2
        echo "Place it: ndh-identity-push ${machine} from bioskop, or ndh-identity-receive --accept at ${machine}'s console." >&2
        exit 1
      '';
      description = "Fails, naming the file and the gesture that places it, when the machine's own host key is missing.";
    };
  };
}
