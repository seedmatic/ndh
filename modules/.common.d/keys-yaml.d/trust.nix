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

  # The phase-2 gate. Dropping an authority's old slot moves the signature to the next one,
  # so that slot must be TRUSTED everywhere first: an ordinary retirement (a revoked
  # `<authority>@<slot>` not marked `compromised`) requires the signing slot that remains to
  # carry `trusted: <YY-MM-DD>`, the date `ndh-trust-check` passed on every host. A
  # compromised generation is retired at once, breakage accepted, so it is exempt.
  # Returns the revoked ids that break the gate.
  phase2Gaps =
    authorities: revoked:
    lib.attrNames (
      lib.filterAttrs (
        id: entry:
        let
          name = lib.head (lib.splitString "@" id);
          remaining = lib.filterAttrs (_: m: !isCompromised m) (authorities.${name}.slots or { });
          signing = lib.head (lib.sort lib.lessThan (lib.attrNames remaining) ++ [ null ]);
        in
        authorities ? ${name}
        && !(entry.compromised or false)
        && (signing == null || (remaining.${signing}.trusted or "") == "")
      ) revoked
    );
}
