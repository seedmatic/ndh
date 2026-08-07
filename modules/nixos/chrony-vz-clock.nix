{ config, lib, ... }:
# VZ (Apple-Virtualization / Tart) NixOS guests lose wall-clock time across a
# host sleep/resume: on wake, both the guest clock AND its emulated RTC lag by
# the full suspend duration (observed ~10-12 min behind the Mac host after one
# sleep). systemd-timesyncd only SLEWS small drifts and keeps reporting
# "System clock synchronized: yes" off a stale sync — it never STEP-corrects a
# multi-minute post-resume gap. The skew cascades: a nested Incus guest inherits
# it via kvm-clock, and rke2 mints a CA with notBefore in the skewed frame,
# yielding an "x509: certificate is not yet valid" boot loop that wedges
# rke2lab.target. Replace timesyncd with chrony set to STEP on any offset,
# unbounded (makestep 1.0 -1), so every host wake is corrected immediately.
# Guest-only (gated on vm.role): the fix is meaningless on the Mac host, and
# services.chrony is NixOS-only — it must not land in a nix-darwin evaluation.
{
  config = lib.mkIf (config.vm.role == "guest") {
    services.timesyncd.enable = false;
    services.chrony = {
      enable = true;
      # Keep the default nixpkgs NTP pool servers (the guest already reaches
      # 2.nixos.pool.ntp.org); only change the correction discipline to always
      # step. The nixpkgs chrony module already trims the emulated RTC for us
      # (enableRTCTrimming -> rtcautotrim), which is what keeps the RTC aligned
      # across resumes — an explicit `rtcsync` here would conflict with it and
      # crash chrony, so we leave RTC handling to the module default.
      extraConfig = ''
        makestep 1.0 -1
      '';
    };
  };
}
