# Every sops file a machine decrypts is encrypted to its access point's recipient (ssh-to-age of its operator
# seat's recorded host-key public, the seat's own for an operator seat), and, for a NixOS guest, to the identity
# it holds today, read from each file's own metadata: a push of the new identity then lands on files it already
# opens (S4). `current` is "" for a seat, whose sops identity is its own host key.
{
  pkgs,
  name,
  files,
  seatPublic,
  current,
}:
let
  # A sops file path read from a configuration as a source path has lost its store context, so the build
  # sandbox would refuse it: give it back its store root as an input. A derived file keeps its own.
  withContext =
    f:
    if builtins.hasContext (toString f) then
      toString f
    else
      let
        root = pkgs.lib.concatStringsSep "/" (pkgs.lib.take 4 (pkgs.lib.splitString "/" (toString f)));
      in
      builtins.appendContext (toString f) {
        ${root} = {
          path = true;
        };
      };
in
pkgs.runCommand "sops-access-point-recipients-${name}"
  {
    nativeBuildInputs = [
      pkgs.ssh-to-age
      pkgs.yq-go
    ];
  }
  ''
    expected="$(printf 'ssh-ed25519 %s\n' ${pkgs.lib.escapeShellArg seatPublic} | ssh-to-age)"
    fail=0
    for f in ${pkgs.lib.escapeShellArgs (map withContext files)}; do
      recipients="$(yq -r '.sops.age[].recipient' "$f")"
      for r in "$expected" ${
        pkgs.lib.optionalString (current != "") (pkgs.lib.escapeShellArg current)
      }; do
        if ! grep -qxF "$r" <<<"$recipients"; then
          echo "$f is not encrypted to $r" >&2
          fail=1
        fi
      done
    done
    [ "$fail" = 0 ]
    touch $out
  ''
