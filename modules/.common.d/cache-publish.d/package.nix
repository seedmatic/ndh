# cache-publish, with its environment fixed at evaluation: the allow-list, the public cache, the
# upstreams that make a path already public, and where the push token is.
{
  pkgs,
  lib,
  outputs,
  cache,
  publicUrl,
  upstreams,
  tokenFile,
}:
pkgs.writeShellApplication {
  name = "cache-publish";
  runtimeInputs = with pkgs; [
    cachix
    coreutils
    curl
    findutils
    gawk
    gnugrep
    yq-go
  ];
  text = ''
    OUTPUTS=${lib.escapeShellArg (lib.concatStringsSep "\n" outputs)}
    CACHE=${lib.escapeShellArg cache}
    PUBLIC_URL=${lib.escapeShellArg publicUrl}
    UPSTREAMS=${lib.escapeShellArg (lib.concatStringsSep "\n" upstreams)}
    TOKEN_FILE=${lib.escapeShellArg tokenFile}
    JOBS=16
  ''
  + builtins.readFile ./cache-publish.sh;
}
