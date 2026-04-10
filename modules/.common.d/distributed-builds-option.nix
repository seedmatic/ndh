{ lib, ... }:

{
  options.services.crossHostBuilders = {
    enable = lib.mkEnableOption "cross host builders configuration";
  };
}
