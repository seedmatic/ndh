{
  self,
  paths,
  profile,
  ndhContext,
  ndhStore,
  vmConfigMaterializerPackage,
  keysYamlPath,
}:
{
  inherit self paths profile;
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
