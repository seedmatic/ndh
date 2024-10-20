inputs: final: prev: {
  flox-pkgdb =
    builtins.trace "Applying flox overlay"
    (prev.flox.overrideAttrs (oldAttrs: {
      patches = (oldAttrs.patches or []) ++ [./flox-maybeGetAttr.patch];
      prePatch = ''
        ${oldAttrs.prePatch or ""}
        echo "Starting prePatch phase"
      '';
      postPatch = ''
        ${oldAttrs.postPatch or ""}
        echo "Starting postPatch phase"
        echo "Content of src/buildenv/realise.cc after patching:"
        cat src/buildenv/realise.cc
        echo "Ending postPatch phase"
      '';
      postUnpack = ''
        ${oldAttrs.postUnpack or ""}
        echo "Starting postUnpack phase"
        echo "Current directory: $(pwd)"
        ls -la
      '';
      # Force a rebuild by changing the version
      version = "${oldAttrs.version}-patched";
    }))
    .override {
      nix = final.nix; # Ensure we're using the latest nix from the final set
    };
}
