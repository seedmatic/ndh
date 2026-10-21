# Whether a machine serves its OWN host key, placed by ndh-identity-push, or the shared rdp-host (roles × keys
# S3a). One declaration for NixOS guests and operator seats; the platform openssh modules read it.
{
  config,
  lib,
  pkgs,
  ndh,
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

    # Not read-only only so the eval checks can give a test configuration a pending slot keys.yaml does not hold.
    entry = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      internal = true;
      default = config.ndh.keysYaml.keys."host-${machine}" or { };
      description = "keys.yaml's host-<hostName> entry, the slots this module reads.";
    };

    slotDir = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = "/var/lib/ndh/host-key/slots";
      description = ''
        Where a key born on the machine lives, one directory per keys.yaml slot (<slotDir>/<slot>/), beside the key
        served and never over it: a rotation generates the next key while sshd still serves the current one.
      '';
    };

    publishDir = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = "/var/lib/ndh/host-key/published";
      description = "Where a generated key's public and its F1 statement wait for the seat to collect them: publics only.";
    };

    servedKeyFile = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = lib.head config.opensshPolicy.hostKeyPaths;
      description = ''
        The host key this machine's sshd serves now, whose certificate keys.yaml records: it signs the F1 statement
        that vouches for a newly generated key.
      '';
    };

    generateVars = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      internal = true;
      description = "The values ndh-host-key-generate is rendered with, shell-quoted, fixed at evaluation for the pending slot.";
    };

    generate = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      internal = true;
      description = "ndh-host-key-generate for this machine's pending host-key slot, or null when none is pending.";
    };
  };

  config =
    let
      entry = cfg.entry;
      roles = import ./host-key.d/slots.nix { inherit lib; } entry;
      serving = (roles.current.state or "") == "serving";
      pendingName = roles.pendingName;
    in
    {
      # keys.yaml's slot state and this flag say the same thing (roles × keys K1): a machine serves its own host
      # key exactly when its current slot is `serving`. Until the flag is derived from the state, a drift either
      # way is refused here, before any host is switched.
      assertions = [
        {
          assertion = cfg.own == serving;
          message = ''
            ${machine}: ndh.hostKey.own is ${lib.boolToString cfg.own}, but keys.yaml's current host-${machine} slot is
            ${
              if roles.currentName == null then "absent" else "in state `${roles.current.state or "(none)"}`"
            }: a machine serves its own host key
            exactly when that slot is `serving`. Change both in the same commit.'';
        }
      ];

      # A pending slot (declared in keys.yaml, no key yet): the activation generates its key in its own slot
      # directory and publishes its public and the F1 statement for the seat to collect (host-key.d/generate.sh).
      # Nothing serves it. With no pending slot, as today on every machine, nothing of this is built.
      ndh.hostKey.generateVars = lib.mkIf (pendingName != null) (
        lib.mapAttrs (_: lib.escapeShellArg) {
          inherit machine;
          slot = pendingName;
          keyFile = "${cfg.slotDir}/${pendingName}/ssh_host_ed25519_key";
          inherit (cfg) publishDir;
          oldKey = cfg.servedKeyFile;
          oldPublic = "${entry.type or "ssh-ed25519"} ${roles.current.public or ""}";
        }
      );
      # The ndh bash trampoline and logger, like every activation script; ssh-keygen and coreutils by store path.
      ndh.hostKey.generate = lib.mkIf (pendingName != null) (
        ndh.store.installBinScript "host-key-generate" (
          pkgs.replaceVars ./host-key.d/generate.sh (
            cfg.generateVars // { inherit (ndh.context) nixBashTrampoline; }
          )
        )
      );
    };
}
