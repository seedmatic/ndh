{
  worktreePath,
  lib,
  pkgs,
  ...
}:
# Single source of truth for build-time extractions of
# modules/home-manager/ssh.d/keys.yaml.
#
# Every consumer reads keys.yaml's data from this module, never from the file itself, and the "which key
# names go into root's authorized_keys" decision is a list of names, not an open-coded conditional per key.
let
  # keys.yaml's public view, keys.json, committed next to it (keys-yaml.d/public.yq): nix reads no YAML, and
  # reading a yq run's output here was import-from-derivation. checks.<system>.keys-json-fresh holds it to
  # keys.yaml.
  keysJsonFile = worktreePath.of "modules/home-manager/ssh.d/keys.json";
  parsed = builtins.fromJSON (builtins.readFile keysJsonFile);
  keysJson = parsed.keys or { };
  authoritiesJson = parsed.authorities or { };
  revokedJson = parsed.revoked or { };
  trust = import ./keys-yaml.d/trust.nix { inherit lib; };

  # Every public blob a slot still carries, keys and authorities alike.
  livePublics =
    lib.concatMap
      (
        entries:
        lib.concatMap (
          entry: lib.mapAttrsToList (_slot: material: material.public or "") (entry.slots or { })
        ) (lib.attrValues entries)
      )
      [
        keysJson
        authoritiesJson
      ];

  # A revoked key that a slot still carries would refuse its own users — the
  # sshd that reads this list would lock out every client still presenting it.
  stillLive = lib.filterAttrs (_id: r: lib.elem r.public livePublics) revokedJson;

  phase2Gaps = trust.phase2Gaps authoritiesJson revokedJson;

  # Roles × keys 6a: every SSH certificate (ssh-host, ssh-user) is signed on the operator seat and recorded
  # in keys.yaml; the activation only installs it and signs nothing. So a generation of a key with an
  # SSH cert_usage must carry its recorded public AND its recorded certificate — otherwise its host
  # would have none. Refused here, before any host is switched.
  uncertified = lib.concatLists (
    lib.mapAttrsToList (
      name: key:
      lib.concatMap (
        usage:
        lib.concatLists (
          lib.mapAttrsToList (
            slot: material:
            if (material.public or "") == "" then
              [ "${name}@${slot} ${usage} (no recorded material)" ]
            else
              lib.optional (
                ((material.certificates or { }).${key.authority} or { }).${usage} or "" == ""
              ) "${name}@${slot} ${usage} (no recorded certificate)"
          ) (key.slots or { })
        )
      ) (lib.filter (u: u == "ssh-host" || u == "ssh-user") (key.cert_usage or [ ]))
    ) (lib.filterAttrs (_: key: (key.authority or null) != null) keysJson)
  );

  krlFile =
    if stillLive != { } then
      throw ''
        ndh.keysYaml: revoked but still carried by a slot in keys.yaml: ${lib.concatStringsSep ", " (lib.attrNames stillLive)}
        A generation is revoked in the same change that deletes its slot, never before.''
    else if uncertified != [ ] then
      throw ''
        ndh.keysYaml: SSH certificates not recorded: ${lib.concatStringsSep ", " uncertified}
        Record the material on the operator seat (ssh-keys-renew), sign it (ssh-keys-certify --apply), and commit
        keys.yaml (roles × keys 6a).''
    else if phase2Gaps != [ ] then
      throw ''
        ndh.keysYaml: authority generation retired before its successor was trusted everywhere: ${lib.concatStringsSep ", " phase2Gaps}
        Run ndh-trust-check on every host, then record `trusted: <YY-MM-DD>` on the slot that now signs
        (docs/ssh-keys-renewal-spec.adoc, phase 2 of an authority). A compromised generation is marked
        `compromised: true` in revoked instead.''
    else
      pkgs.runCommand "ndh-revoked-keys.krl" {
        nativeBuildInputs = [
          pkgs.openssh
          pkgs.yq-go
        ];
      } "bash ${./keys-yaml.d/krl.sh} ${keysJsonFile} $out";
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
        authority's `domain`, `usage`, and per slot its `public` and `ca_crt`.
        (private is sops-encrypted and stays ENC[...] here; the only
        consumer that needs it reads from the enriched keys.yaml
        at activation time).
      '';
    };

    trustedAuthoritySlots = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
      readOnly = true;
      default = trust.trustedSlots authoritiesJson;
      description = ''
        Per authority, the slots every trust store carries: all of them except a slot
        marked `compromised` (keys-yaml.d/trust.nix). The only source the trust paths read.
      '';
    };

    compromisedAuthoritySlots = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
      readOnly = true;
      default = trust.compromisedSlots authoritiesJson;
      description = ''
        Per authority, the slots marked `compromised`: removed from every trust store,
        including a root an earlier activation already installed.
      '';
    };

    krlFile = lib.mkOption {
      type = lib.types.path;
      readOnly = true;
      default = krlFile;
      description = ''
        The fleet's key revocation list, sshd's RevokedKeys and every client's
        RevokedHostKeys: the publics of `.revoked` in keys.yaml, and each certificate
        of `.revoked_certificates` by its exact key id under the authority slot that
        signed it (keys-yaml.d/krl.sh). A STORE path on purpose — sshd refuses ALL
        public-key authentication when this file is unreadable, so it must not
        depend on an activation step that can fail. Refuses to evaluate if a revoked
        key is still carried by a slot, and to build if a live certificate shares a
        revoked key id.
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
