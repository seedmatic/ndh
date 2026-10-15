# The secret-material guard of the bringup images (see secret-material-guard.d/guard.sh), with its
# tools at absolute paths, so the same script runs in a store layer's builder and inside the nested
# guest that writes the target root.
{ pkgs }:
pkgs.replaceVars ./secret-material-guard.d/guard.sh {
  # The file alone in the store: a path value here would name it inside the whole flake source.
  allowList = "${./secret-material-guard.d/public-test-keys.sha256}";
  grep = "${pkgs.gnugrep}/bin/grep";
  awk = "${pkgs.gawk}/bin/awk";
  sha256sum = "${pkgs.coreutils}/bin/sha256sum";
  find = "${pkgs.findutils}/bin/find";
  xargs = "${pkgs.findutils}/bin/xargs";
  bash = "${pkgs.bash}/bin/bash";
}
