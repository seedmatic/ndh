# keys.yaml holds to keys.schema.yaml, as the pre-commit formatter checks it (treefmt's keys-schema): a flake check too,
# so a merge that commits no file through the formatter (a window's branch, merged) is held to it as well. keys.yaml
# is read as committed, its sops values as strings, like the formatter reads it. Its control: a bootstrap slot past
# pending refused again, as the schema had it before 2026-10-26, must refuse today's keys.yaml (window 1 recorded two).
# And a retired name coming back (an sshfs-<guest> key, rdp-host) is refused.
{
  pkgs,
  keysYaml,
  keysSchema,
}:
pkgs.runCommand "keys-yaml-schema"
  {
    nativeBuildInputs = with pkgs; [
      check-jsonschema
      gnugrep
      yq-go
    ];
  }
  ''
    check-jsonschema --schemafile ${keysSchema} ${keysYaml}
    yq '.["$defs"].machineSlots.additionalProperties.then.properties.state = {"const": "pending"}' ${keysSchema} >mutant.yaml
    if check-jsonschema --schemafile mutant.yaml ${keysYaml} >mutant.out 2>&1; then
      echo "FAIL the control schema (bootstrap only while pending) accepted keys.yaml: the check proves nothing"; exit 1
    fi
    grep -q "'pending' was expected" mutant.out
    for retired in sshfs-x rdp-host; do
      N=$retired yq '.keys[strenv(N)] = .keys.operator' ${keysYaml} >back.yaml
      if check-jsonschema --schemafile ${keysSchema} back.yaml >back.out 2>&1; then
        echo "FAIL keys.yaml with a $retired entry passed the schema: a retired name can come back"; exit 1
      fi
      grep -q "should not be valid under" back.out
    done
    touch $out
  ''
