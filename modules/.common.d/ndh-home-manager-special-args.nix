{
  self,
  worktreePath,
  profile,
  ndhContext,
  ndhStore,
  vmConfigMaterializerPackage,
  keysYamlPath,
}:
{
  inherit self worktreePath profile;
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
