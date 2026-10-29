# Whether a machine serves its OWN host key or the shared rdp-host, read from keys.yaml's slot state (roles × keys
# S3a, K5), and the key born on it for a pending slot (K3). One declaration for NixOS guests and operator seats; the
# platform openssh modules read it.
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
      readOnly = true;
      default =
        ((import ./host-key.d/slots.nix { inherit lib; } cfg.entry).current.state or "") == "serving";
      description = ''
        Whether this machine serves its own host key, at `ndh.hostKey.file`, with the certificate keys.yaml records
        for `<hostName>`: read from keys.yaml, true exactly when its current slot is `serving` (roles × keys
        K5). Never set by hand: a slot reaches `serving` only once its key is there and certified.
      '';
    };

    # A key born on the machine (K3) is served where it was generated, in its slot's directory: nothing copies it, so
    # there is no moment it is missing. A key pushed before K5 stays at the fixed path it was pushed to.
    file = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default =
        let
          roles = import ./host-key.d/slots.nix { inherit lib; } cfg.entry;
        in
        if (roles.current.origin or "") == "host" then
          "${cfg.slotDir}/${roles.currentName}/ssh_host_ed25519_key"
        else
          "/var/lib/ndh/host-key/ssh_host_ed25519_key";
      description = "Where the machine's own host key of its current slot lives: its slot's directory for a key born on it, the fixed path for one pushed before K5.";
    };

    # Not read-only only so the eval checks can give a test configuration a certificate that keys.yaml
    # does not hold.
    certificate = lib.mkOption {
      type = lib.types.str;
      internal = true;
      default = import ./host-key.d/certificate.nix { inherit lib; } config.ndh.keysYaml.keys machine;
      description = "The ssh-host certificate recorded in keys.yaml for <hostName>; refuses to evaluate without one.";
    };

    certificateFile = lib.mkOption {
      type = lib.types.path;
      readOnly = true;
      default = pkgs.writeText "${machine}-host-cert.pub" "${cfg.certificate}\n";
      description = "HostCertificate: a store file, as the certificate is public.";
    };

    check = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = pkgs.writeShellScript "ndh-host-key-check" ''
        [[ -s ${cfg.file} ]] && exit 0
        echo "ERROR: ${cfg.file} is missing, and ${machine}'s sshd serves no other host key (ndh.hostKey.own)." >&2
        echo "Its current slot is serving, so keys.yaml expects it there: a key born on it is generated there by its pending slot's activation (ops next)." >&2
        exit 1
      '';
      description = "Fails, naming the file and the gesture that places it, when the machine's own host key is missing.";
    };

    # Not read-only only so the eval checks can give a test configuration a pending slot keys.yaml does not hold.
    entry = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      internal = true;
      default = config.ndh.keysYaml.allSlots.${machine} or { };
      description = "keys.yaml's <hostName> entry, the slots this module reads.";
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
      pendingName = roles.pendingName;
    in
    {
      assertions = [
        {
          # slots.nix takes the newest usable slot for the current one: a pending slot named before it would be
          # generated, recorded, and then never served.
          assertion = pendingName == null || roles.currentName == null || roles.currentName < pendingName;
          message = "${machine}: ${machine}@${toString pendingName} is pending, but it does not sort after the current slot ${toString roles.currentName}: name the new slot by a later date.";
        }
      ];

      # A pending slot (declared in keys.yaml, no key yet): the activation generates its key in its own slot
      # directory and publishes its public and the F1 statement for the seat to collect (host-key.d/generate.sh).
      # Nothing serves it. A machine with no pending slot builds none of this.
      ndh.hostKey.generateVars = lib.mkIf (pendingName != null) (
        lib.mapAttrs (_: lib.escapeShellArg) {
          inherit machine;
          slot = pendingName;
          base = "/var/lib/ndh";
          inherit (cfg) slotDir;
          owner = "0";
          keyFile = "${cfg.slotDir}/${pendingName}/ssh_host_ed25519_key";
          inherit (cfg) publishDir;
          oldKey = cfg.servedKeyFile;
          oldPublic = "${entry.type or "ssh-ed25519"} ${roles.current.public or ""}";
          bootstrap = entry.slots.${pendingName}.bootstrap or "";
          # The machine's console: what the operator reads at its screen (a NixOS guest's tty, a darwin host's).
          console = "/dev/console";
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
