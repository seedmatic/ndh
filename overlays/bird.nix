inputs: final: prev: {
  bird = let
    birdPkg = inputs.bird.packages.${prev.system}.default;
  in
    builtins.traceVerbose "Bird package: ${builtins.toJSON birdPkg.meta}, sysioMd5sum: ${birdPkg.passthru.sysioMd5sum}" birdPkg;
}
