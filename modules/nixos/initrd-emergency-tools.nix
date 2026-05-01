# Single source of truth for the forensic/disk-recovery toolset that must be
# present in the initrd emergency shell across ALL NixOS configurations.
#
# Returns an attrset with two keys:
#   extraBin   — attrset for boot.initrd.systemd.extraBin (creates /bin symlinks)
#   storePaths — list for boot.initrd.systemd.storePaths  (embeds closures in cpio)
#
# IMPORTANT: both are required. extraBin creates the /bin/<name> symlinks inside
# the initrd, but the symlink targets (/nix/store/...) are dangling until their
# closures are also embedded via storePaths. Without storePaths, the tools are
# present as broken symlinks and "command not found" at runtime.
#
# The same packages are also referenced in bringup-zfs-disk-image.nix to keep
# the bringup shell PATH consistent with what is available in stage-1 recovery.
pkgs:
let
  # Each entry: { bin = "name"; pkg = pkgs.foo; path = "bin/foo"; }
  # path defaults to "bin/<name>" if omitted.
  entries = [
    # ── Text search / stream processing ─────────────────────────────────────
    { bin = "grep";    pkg = pkgs.gnugrep;    path = "bin/grep"; }
    { bin = "egrep";   pkg = pkgs.gnugrep;    path = "bin/egrep"; }
    { bin = "sed";     pkg = pkgs.gnused;     path = "bin/sed"; }
    { bin = "awk";     pkg = pkgs.gawk;       path = "bin/awk"; }

    # ── Disk / partition tooling ─────────────────────────────────────────────
    { bin = "sgdisk";  pkg = pkgs.gptfdisk;   path = "bin/sgdisk"; }
    { bin = "hexdump"; pkg = pkgs.util-linux; path = "bin/hexdump"; }
    { bin = "lsblk";   pkg = pkgs.util-linux; path = "bin/lsblk"; }
    { bin = "blkid";   pkg = pkgs.util-linux; path = "bin/blkid"; }
    { bin = "partx";   pkg = pkgs.util-linux; path = "bin/partx"; }
    { bin = "fdisk";   pkg = pkgs.util-linux; path = "bin/fdisk"; }

    # ── ZFS ──────────────────────────────────────────────────────────────────
    { bin = "zdb";     pkg = pkgs.zfs;        path = "bin/zdb"; }

    # ── Terminal helpers ──────────────────────────────────────────────────────
    # xterm provides `resize` — needed to fix terminal geometry after socat attach.
    { bin = "resize";  pkg = pkgs.xterm;      path = "bin/resize"; }
  ];

  extraBin = builtins.listToAttrs (
    map (e: { name = e.bin; value = "${e.pkg}/${e.path}"; }) entries
  );

  # Deduplicate packages — util-linux appears multiple times.
  storePaths = pkgs.lib.unique (map (e: e.pkg) entries);
in
{ inherit extraBin storePaths; }
