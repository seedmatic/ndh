# ndh-keys-json: rewrite keys.json, keys.yaml's public view for nix (public.yq), from a keys.yaml given as its one
# argument. One definition, for the flake's tools and app and for keys-reconcile's window.
{ pkgs }:
pkgs.writeShellApplication {
  name = "ndh-keys-json";
  runtimeInputs = with pkgs; [
    coreutils
    gnugrep
    yq-go
  ];
  text = ''
    set -- ${./public.yq} "$@"
  ''
  + builtins.readFile ./keys-json.sh;
}
