{
  self,
  inputs,
  config,
  pkgs,
  ...
}:
let

  user = config.profile.user;

in
{
  user = {

    # programs.git = {
    #   enable = true; # Important: explicitly enable the program
    #   signing = {
    #     key = user.email;
    #     signByDefault = false;
    #   };
    #   userEmail = user.email;
    #   userName = user.name;
    # };

  };
}
