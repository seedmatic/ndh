{
  self,
  worktreePath,
  profile,
  ndhContext,
  ndhStore,
  keysYamlPath,
}:
{
  inherit
    self
    worktreePath
    profile
    ;
  ndh = {
    context = ndhContext;
    store = ndhStore;
    ssh = {
      inherit keysYamlPath;
    };
  };
}
