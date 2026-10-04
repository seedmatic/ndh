{
  worktreePath,
  lib,
  pkgs,
  ...
}:
# Single source of truth for build-time extractions of
# modules/home-manager/ssh.d/keys.yaml.
#
# Every consumer that previously inlined a `pkgs.runCommand` running
# `yq -o=json '.keys' keys.yaml` + a fromJSON + an authorized_keys line
# builder should read from this module instead. Collapses duplicated
# store derivations to a single one and keeps the "which key names go
# into root's authorized_keys" decision expressed as a list of names,
# not an open-coded conditional per key.
let
  # Single runCommand extracts both `.keys` and `.authorities` maps as
  # JSON so every consumer reads from the same store path.  sops
  # leaves plaintext fields (anything without a `# sops:encrypted`
  # marker in .sops.yaml's encrypted_comment_regex, including
  # `public`, `ca_crt`, everything under `authorities`) untouched,
  # so yq can pull them out of the encrypted file directly without
  # sops decryption at eval time.
  jsonDrv = pkgs.runCommand "ndh-keys-yaml.json" { buildInputs = [ pkgs.yq-go ]; } ''
    yq -o=json '{"keys": .keys, "authorities": .authorities}' \
      "${worktreePath.of "modules/home-manager/ssh.d/keys.yaml"}" > "$out"
  '';
  parsed = builtins.fromJSON (builtins.readFile jsonDrv);
  keysJson = parsed.keys or { };
  authoritiesJson = parsed.authorities or { };
in
{
  options.ndh.keysYaml = {
    keys = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      readOnly = true;
      default = keysJson;
      description = ''
        Parsed `.keys` map from `modules/home-manager/ssh.d/keys.yaml`.
        The build-time derivation producing the JSON is shared via the
        Nix store so consumers never rebuild it.
      '';
    };

    authorities = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      readOnly = true;
      default = authoritiesJson;
      description = ''
        Parsed `.authorities` map from keys.yaml.  Carries each
        authority's `public`, `ca_crt`, `domain`, `usage`, etc.
        (private is sops-encrypted and stays ENC[...] here; the only
        consumer that needs it reads from the enriched keys.yaml
        at activation time).
      '';
    };

    authorizedLinesFor = lib.mkOption {
      type = lib.types.functionTo (lib.types.listOf lib.types.str);
      readOnly = true;
      default =
        names:
        lib.concatMap (
          name:
          let
            entry =
              keysJson.${name} or (throw "ndh.keysYaml.authorizedLinesFor: no key named '${name}' in keys.yaml");
            usable = lib.filterAttrs (
              _slot: material: (material.public or "") != "" && !(lib.hasPrefix "ENC[" material.public)
            ) (entry.slots or { });
            lines = lib.mapAttrsToList (
              _slot: material: "${entry.type or "ssh-ed25519"} ${material.public} ndh-${name}"
            ) usable;
          in
          if lines == [ ] then
            throw "ndh.keysYaml.authorizedLinesFor: key '${name}' has no slot carrying a usable public key"
          else
            lines
        ) names;
      description = ''
        Given a list of key names from keys.yaml, return the matching
        authorized_keys lines in the shape `<type> <blob> ndh-<name>` —
        *one line per slot*, because every generation of a key is accepted
        while only the newest is presented. That asymmetry is what makes a
        renewal survivable: see docs/ssh-keys-renewal-spec.adoc.

        A name absent from keys.yaml, or present with no slot carrying a
        usable public key, is an eval **error**. It used to be dropped
        silently, and when the entries moved from a flat `public` into
        dated slots every call site started returning the empty list
        without a word — including root's authorized_keys and the initrd
        rescue door. An access list that can be silently empty is worse
        than one that refuses to build.
      '';
    };
  };
}
