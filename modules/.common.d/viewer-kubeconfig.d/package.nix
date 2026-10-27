# viewer-kubeconfig (see viewer-kubeconfig.sh): the sessions' read-only kubeconfig, one of ndh-ops's tools, so it runs
# only on a delegation the operator armed. It reads their admin kubeconfig; sessions only ever see the file it writes.
{ pkgs }:
pkgs.writeShellApplication {
  name = "viewer-kubeconfig";
  runtimeInputs = with pkgs; [
    coreutils
    jq
    kubectl
  ];
  text = builtins.readFile ./viewer-kubeconfig.sh;
}
