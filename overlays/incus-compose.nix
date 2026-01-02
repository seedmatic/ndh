# overlays/incus-compose.nix
inputs: final: prev: {
  incus-compose =
    let
      basePackage =
        inputs.incus-compose.packages.${prev.system}.incus-compose or prev.incus-compose or null;
    in
    if basePackage != null then
      basePackage.overrideAttrs (old: {
        vendorHash = null;
      })
    else
      basePackage;
}
