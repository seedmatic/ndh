inputs: final: prev: {
  bird =
    let
      hostSystem = prev.stdenv.hostPlatform.system;
      birdPkg = inputs.bird.packages.${hostSystem}.default;
    in
    builtins.traceVerbose "Bird package: ${builtins.toJSON birdPkg.meta}, sysioMd5sum: ${birdPkg.passthru.sysioMd5sum}" birdPkg;
}
