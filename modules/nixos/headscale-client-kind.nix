# NixOS hosts default to the `nixos` kind (tag:headless,tag:nixos).
# Imported by both the full config (via modules/nixos/default.nix) and
# the minimal bringup image — both paths need the same kind dispatch.
# A host that runs a non-default kind (e.g. an incus or rke2 node)
# overrides `ndh.tailnetClient.kind` in its own host profile with
# `lib.mkForce`.
{ lib, ... }:
{
  ndh.tailnetClient.kind = lib.mkDefault "nixos";
}
