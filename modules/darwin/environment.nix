{ config, lib, pkgs, ... }: {
  config = {
    environment = {

      systemPackages = with pkgs; [ zsh flox direnv ];

      shells =
        [ "/run/current-system/sw/bin/bash" "/run/current-system/sw/bin/zsh" ];
    };

  };
}
