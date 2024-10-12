{
  pkgs,
  inputs,
  ...
}: let
  floxPkgdbPatch = ./flox.patch;

  debugPhase = phase: ''
    echo "Debug: ${phase} phase directory: $(pwd)"
    echo "Debug: Grepping maybeGetAttr in current directory:"
    grep -r maybeGetAttr . || echo "No matches found"
  '';

  patchedFloxPkgdb = (pkgs.extend inputs.flox.overlays.default).flox-pkgdb.overrideAttrs (oldAttrs: {
    patches = (oldAttrs.patches or []) ++ [floxPkgdbPatch];

    prePatch = ''
      ${oldAttrs.prePatch or ""}
      ${debugPhase "PrePatch"}
    '';

    postPatch = ''
      ${oldAttrs.postPatch or ""}
      ${debugPhase "PostPatch"}
    '';

    preBuild = ''
      ${oldAttrs.preBuild or ""}
      ${debugPhase "PreBuild"}
    '';

    buildPhase = ''
      ${oldAttrs.buildPhase or ""}
      echo "Debug: Content of src/buildenv/realise.cc before compilation:"
      cat src/buildenv/realise.cc
    '';

    postBuild = ''
      ${oldAttrs.postBuild or ""}
      ${debugPhase "PostBuild"}
    '';

    # NIX_DEBUG = "1";
  });

  patchedFlox = (pkgs.extend inputs.flox.overlays.default).flox.override (oldAttrs: {
    flox-pkgdb = patchedFloxPkgdb;
  });
in {
  environment.systemPackages = [patchedFlox];

  nixpkgs.overlays = [
    (final: prev: {
      flox-pkgdb = patchedFloxPkgdb;
      flox = final.flox.override (oldAttrs: {
        flox-pkgdb = patchedFloxPkgdb;
      });
    })
  ];
}
