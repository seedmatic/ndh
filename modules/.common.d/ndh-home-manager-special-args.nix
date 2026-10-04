{
  self,
  worktreePath,
  profile,
  ndhContext,
  ndhStore,
  keysYamlPath,
  claude-hub ? null,
}:
{
  inherit
    self
    worktreePath
    profile
    claude-hub
    ;
  ndh = {
    context = ndhContext;
    store = ndhStore;
    ssh = {
      inherit keysYamlPath;
    };
  };
}
