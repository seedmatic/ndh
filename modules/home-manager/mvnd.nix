{inputs, ...}: {
  programs.maven-mvnd = {
    enable = true;
    package = inputs.maven-mvnd.packages.maven-mvnd-m39;
    command = "mvnd.sh";
  };
}
