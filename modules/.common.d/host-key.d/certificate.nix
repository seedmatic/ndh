# The ssh-host certificate keys.yaml records for a machine's own host key `host-<machine>`: its current
# slot's (slots.nix: the newest that is neither pending nor retired), under
# the authority the entry names. Public material: read at evaluation, never at activation.
{ lib }:
keys: machine:
let
  name = machine;
  entry = keys.${name} or { };
  newest = (import ./slots.nix { inherit lib; } entry).current;
  certificate = ((newest.certificates or { }).${entry.authority or ""} or { }).ssh-host or "";
in
if certificate == "" then
  throw ''
    ndh.hostKey.own is set on ${machine}, but keys.yaml records no ssh-host certificate for ${name} (newest slot).
    Record its public (ssh-keys-renew --create ${name} --public - --usage ssh-host), sign it
    (ssh-keys-certify --apply) and commit keys.yaml before turning ndh.hostKey.own on.''
else
  certificate
