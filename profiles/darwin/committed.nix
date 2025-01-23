{ ... }: {
  imports = [ 
    (import ./common.nix { profileName = "committed"; }) 
  ];
  
  user.name = "nxmatic";

  # homebrew = {
  #   brews = [
  #   ];

  #   casks = [
  #     # social
  #     "google-drive"
  #     "notion"
  #     "signal"

  #     # knowledge base
  #     "obsidian"
  #     #      "zotero"

  #     # ide
  #     #      "visual-studio-code" -> nix

  #     # social
  #     "keybase"
  #   ];
  # };

}
