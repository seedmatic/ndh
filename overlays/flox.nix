inputs: final: prev: {
  flox-pkgdb =
    builtins.traceVerbose "Applying flox overlay"
      (prev.flox.overrideAttrs (oldAttrs: {
        patches = (oldAttrs.patches or [ ]) ++ [ ./flox-maybeGetAttr.patch ];
        prePatch = ''
          ${oldAttrs.prePatch or ""}
          echo "Starting prePatch phase"
        '';
        postPatch = ''
          ${oldAttrs.postPatch or ""}
          echo "Starting postPatch phase"
        '';
        postUnpack = ''
          ${oldAttrs.postUnpack or ""}
          echo "Starting postUnpack phase"
        '';
        # Force a rebuild by changing the version
        version = "${oldAttrs.version}-patched";
      })).override
      {
        nix = builtins.traceVerbose "Returning from flox overlay" final.nix; # Ensure we're using the latest nix from the final set
      };
}
