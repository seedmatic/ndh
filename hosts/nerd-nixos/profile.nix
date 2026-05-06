{ hostProfile }:
{ lib, ... }:
{
  config.profile.host = {
    hostName = lib.mkDefault hostProfile.hostName;
    hostAlias = lib.mkDefault hostProfile.hostAlias;
    form = lib.mkDefault hostProfile.form;
    nixosBringupRootFs = lib.mkDefault hostProfile.nixosBringupRootFs;
  };
}
