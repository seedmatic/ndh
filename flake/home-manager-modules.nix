{
  primaryUser = import ../modules/.common.d/primary-user.nix;
  manager = import ../modules/home-manager;
  profile = import ../profile.nix;
}
