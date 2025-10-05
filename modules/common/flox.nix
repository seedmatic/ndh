{ ... }:
{
  environment.etc."nix/flox.conf" = {
    text = ''
      disable_metrics = true
    '';
    mode = "0644";
  };
}
