# The bringup-runtime profile nix-bash-trampoline requires (root's on a host), built for a check that sources the
# real trampoline: exactly the commands its bootstrap check requires. Handed over as NDH_BOOTSTRAP_PROFILE_DIR, the
# variable the trampoline reads, so a suite never depends on the host's own profile leaking into the sandbox.
{ pkgs }:
pkgs.symlinkJoin {
  name = "ndh-bootstrap-profile";
  paths = with pkgs; [
    age
    bash
    gawk
    git
    gnugrep
    gnused
    nix
    openssh
    yq-go
  ];
}
