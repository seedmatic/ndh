# Bootstrap Lab (standalone, no NDH module wiring)

This sandbox is intentionally isolated from `nix-darwin-home` modules.
Focus now: validate serial console + basic boot path first.

Order of work:

1. minimal single-disk bootstrap with **GRUB**
2. same bootstrap with **systemd-boot**
3. only after both stable: return to ZFS bootstrap experiments

## Why this exists

- Fast image-builder experimentation without changing production modules.
- Reproducible flake output pinned to latest stable NixOS branch (`nixos-25.11`).
- Explicit 3-disk `raidz1` root-pool experiment to mirror NDH topology intent.

## What this flake exposes

- `packages.aarch64-darwin.bootstrap-grub-image-aarch64`
  - Single-disk bootstrap image (`nixos.img`) with GRUB + serial config.
- `packages.aarch64-darwin.bootstrap-systemd-boot-image-aarch64`
  - Single-disk bootstrap image (`nixos.img`) with systemd-boot + serial kernel params.
- `apps.aarch64-darwin.show-bootstrap-grub-layout`
- `apps.aarch64-darwin.show-bootstrap-systemd-boot-layout`
- `apps.aarch64-darwin.materialize-bootstrap-grub-tart`
- `apps.aarch64-darwin.materialize-bootstrap-systemd-boot-tart`

Disk default for bootstrap image:

- single disk: `8192MiB`

## Try it

From this directory:

- Show GRUB bootstrap image layout:
  - `nix run .#show-bootstrap-grub-layout`

- Materialize GRUB bootstrap into Tart VM files:
  - `nix run .#materialize-bootstrap-grub-tart`

- Start GRUB VM:
  - `~/.tart/vms/bootstrap-grub.sh`

- Then repeat for systemd-boot:
  - `nix run .#show-bootstrap-systemd-boot-layout`
  - `nix run .#materialize-bootstrap-systemd-boot-tart`
  - `~/.tart/vms/bootstrap-systemd-boot.sh`

Materializer stops running VM with same name before replacing disk image.

Optional overrides for bootstrap materialization:

- `NDH_BOOTSTRAP_VM_NAME`
- `NDH_BOOTSTRAP_VM_DIR`
- `NDH_BOOTSTRAP_FACTORY_RESET` (`1` => stop/delete/recreate VM before writing disk)

Optional overrides for run wrappers (`~/.tart/vms/bootstrap-*.sh`):

- `NDH_TART_VM_NAME`
- `NDH_TART_BRIDGE_INTERFACE`
- `NDH_TART_BIN`
- `NDH_TART_SERIAL_ENABLE`
- `NDH_TART_GRAPHICS_ENABLE` (`0` default, set `1` for `--vnc-experimental`)
- `NDH_TART_SERIAL_PATH` (if set, wrapper uses `--serial-path=...` instead of `--serial`)

Wrapper default is serial-first (`--no-graphics`).

For Tart/VZ, guest serial usually maps to `hvc0` (virtio console). Current
bootstrap kernels include `console=hvc0` with UART fallbacks.

## Notes

- Helpers in this sandbox:
  - `bootstrap-disk-image.nix` for minimal serial/bootloader validation.
  - `zfs-raidz1-disk-image.nix` kept for later ZFS phase.
- Keep sandbox as proving ground; promote only stable behavior into NDH modules.
