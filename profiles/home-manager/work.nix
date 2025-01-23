{ pkgs, ... }: {
  imports = [ ./common.nix ];

  # Override or extend specific git configurations
  programs.git = {
    userEmail = "stephane.lacoin@hyland.com";
    userName = "Stephane Lacoin (aka nxmatic)";
    signing = {
      key = "stephane.lacoin@hyland.com";
      signByDefault = false;
    };
  };
}

