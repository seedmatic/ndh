{
  self,
  worktreePath,
  profile,
  ndhContext,
  ndhStore,
  vmConfigMaterializerPackage,
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
    vm = {
      configMaterializerPackage = vmConfigMaterializerPackage;
    };
    ssh = {
      inherit keysYamlPath;
    };
  };
}
