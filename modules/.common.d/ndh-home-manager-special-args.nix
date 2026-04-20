{
  profile,
  ndhContext,
  ndhStore,
  vmConfigMaterializerPackage,
  keysYamlPath,
}:
{
  inherit profile;
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
