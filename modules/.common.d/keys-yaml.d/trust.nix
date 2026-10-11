# Which generations of an authority are TRUSTED (keys.schema.yaml, authoritySlots).
#
# Every slot is trusted except one marked `compromised`: a compromised slot stops
# signing AND leaves every trust store, or the leaked private could still mint leaves
# every host accepts. One definition, read by every trust path — NixOS security.pki,
# the darwin System keychain, the ssh known_hosts authorities.
{ lib }:
let
  isCompromised = material: (material.compromised or "") != "";
in
{
  # authorities → { <name> = { <slot> = material; }; } — the slots that are trusted.
  trustedSlots = lib.mapAttrs (_: auth: lib.filterAttrs (_: m: !isCompromised m) (auth.slots or { }));

  # authorities → { <name> = { <slot> = material; }; } — the slots to remove from trust.
  compromisedSlots = lib.mapAttrs (_: auth: lib.filterAttrs (_: isCompromised) (auth.slots or { }));
}
