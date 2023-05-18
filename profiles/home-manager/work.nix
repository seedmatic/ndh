{pkgs, ...}: {

  programs = {

    # version control
    git = {
      userEmail = "stephane.lacoin@hyland.com";
      userName = "Stephane Lacoin (aka nxmatic)";
      signing = {
        key = "stephane.lacoin@hyland.com";
        signByDefault = true;
      };

    };

  };

}
