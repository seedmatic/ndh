{ config, lib, pkgs, ... }:
with lib; {
  meta.maintainers = [ maintainers.uncenter ];

  options.programs.flox = {

    enable = mkEnableOption
      "Developer environments you can take with you a simple, fast and user-friendly.";

    package = mkPackageOption pkgs "flox" { };

  };

  config = let

    cfg = config.programs.flox;

    # args = escapeShellArgs (optional cfg.hidden "--hidden" ++ cfg.extraOptions);

    home.packages = [ cfg.package ];

  in {
    home.packages = [ cfg.package ];
    
  };
}
