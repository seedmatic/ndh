# Whether a sops file read at evaluation is still ciphertext: its sops metadata as a top-level YAML
# mapping, at least one ENC[ value, and no private-key armor. The repository's sops files are YAML (the
# `diff=sops-yaml` attribute), so the JSON form is refused too: it is the one a sops run without
# --input-type yaml writes for an extensionless file.
{ lib }:
content:
(lib.hasPrefix "sops:\n" content || lib.hasInfix "\nsops:\n" content)
&& lib.hasInfix "ENC[" content
&& !(lib.hasInfix "PRIVATE KEY-----" content)
