{ lib, ... }:
{
  programs.gpg.enable = lib.mkForce false;
}
