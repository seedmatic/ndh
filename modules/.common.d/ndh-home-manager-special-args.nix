{
  self,
  profile,
  ndhContext,
  ndhStore,
  vmConfigMaterializerPackage,
  keysYamlPath,
}:
{
  inherit self profile;
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
