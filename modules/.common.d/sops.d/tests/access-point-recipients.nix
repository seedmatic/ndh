# Every sops file a NixOS guest decrypts is encrypted to its access point's recipient (ssh-to-age of its
# operator seat's recorded host-key public) as well as to the identity it holds today, read from each
# file's own metadata: a push of the new identity then lands on files it already opens (S4, first half).
{
  pkgs,
  name,
  files,
  seatPublic,
  current,
}:
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
    for f in ${pkgs.lib.escapeShellArgs files}; do
      recipients="$(yq -r '.sops.age[].recipient' "$f")"
      for r in "$expected" ${pkgs.lib.escapeShellArg current}; do
        if ! grep -qxF "$r" <<<"$recipients"; then
          echo "$f is not encrypted to $r" >&2
          fail=1
        fi
      done
    done
    [ "$fail" = 0 ]
    touch $out
  ''
