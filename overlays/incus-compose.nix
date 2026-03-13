# overlays/incus-compose.nix
inputs: final: prev: {
  incus-compose =
    let
      hostSystem = prev.stdenv.hostPlatform.system;
      basePackage =
        inputs.incus-compose.packages.${hostSystem}.incus-compose or prev.incus-compose or null;
    in
    if basePackage != null then
      basePackage.overrideAttrs (old: {
        vendorHash = null;
      })
    else
      basePackage;
}
