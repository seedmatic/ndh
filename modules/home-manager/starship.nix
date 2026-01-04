{ config, lib, ... }:
{
  programs.starship = {
    enable = lib.mkDefault true;
    settings = {
      # Keep prompt responsive on slow/unreachable mounts (e.g., /net/*)
      scan_timeout = 100; # milliseconds
      # Keep git modules enabled in normal working trees
      git_status.disabled = false;
      git_state.disabled = false;
    };
  };
}
