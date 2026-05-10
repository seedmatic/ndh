{
  self,
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
  jsonDrv = pkgs.runCommand "ndh-keys-yaml.json" { buildInputs = [ pkgs.yq-go ]; } ''
    yq -o=json '.keys' "${self}/modules/home-manager/ssh.d/keys.yaml" > "$out"
  '';
  keysJson = builtins.fromJSON (builtins.readFile jsonDrv);
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

    authorizedLinesFor = lib.mkOption {
      type = lib.types.functionTo (lib.types.listOf lib.types.str);
      readOnly = true;
      default =
        names:
        lib.filter (line: line != "") (
          map (
            name:
            if keysJson ? ${name} && keysJson.${name} ? public then
              "ssh-ed25519 ${keysJson.${name}.public} ndh-${name}"
            else
              ""
          ) names
        );
      description = ''
        Given a list of key names from keys.yaml, return the matching
        authorized_keys lines in the shape
        `ssh-ed25519 <pub> ndh-<name>`. Names missing from keys.yaml or
        without a `.public` field are silently dropped so callers can
        list aspirational keys without hard-failing eval on an empty
        entry.
      '';
    };
  };
}
