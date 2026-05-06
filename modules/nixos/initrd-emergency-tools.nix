# Single source of truth for the forensic/disk-recovery toolset that must be
# present in the initrd emergency shell across ALL NixOS configurations.
#
# Returns an attrset with three keys:
#   extraBin   — attrset for boot.initrd.systemd.extraBin (creates /bin symlinks)
#   storePaths — list for boot.initrd.systemd.storePaths  (embeds closures in cpio)
#   packages   — list of package derivations for lib.makeBinPath (bringup PATH)
#
# IMPORTANT: both are required. extraBin creates the /bin/<name> symlinks inside
# the initrd, but the symlink targets (/nix/store/...) are dangling until their
# closures are also embedded via storePaths. Without storePaths, the tools are
# present as broken symlinks and "command not found" at runtime.
#
# storePaths MUST list the specific binary paths (not whole package derivations).
# make-initrd-ng (used by boot.initrd.systemd) does NOT compute the full Nix
# closure — it traces ELF rpaths from each listed path to find shared libraries.
# Passing a whole package derivation would include every binary in that package
# but would also miss the ELF-dep tracing from the specific binaries we care about.
# See: nixpkgs/pkgs/build-support/kernel/make-initrd-ng/src/main.rs
#
# The same packages are also referenced in bringup-zfs-disk-image.nix to keep
# the bringup shell PATH consistent with what is available in stage-1 recovery.
pkgs:
let
  # Each entry: { bin = "name"; pkg = pkgs.foo; path = "bin/foo"; }
  entries = [
    # ── Text search / stream processing ─────────────────────────────────────
    {
      bin = "grep";
      pkg = pkgs.gnugrep;
      path = "bin/grep";
    }
    {
      bin = "egrep";
      pkg = pkgs.gnugrep;
      path = "bin/egrep";
    }
    {
      bin = "sed";
      pkg = pkgs.gnused;
      path = "bin/sed";
    }
    {
      bin = "awk";
      pkg = pkgs.gawk;
      path = "bin/awk";
    }

    # ── Disk / partition tooling ─────────────────────────────────────────────
    {
      bin = "sgdisk";
      pkg = pkgs.gptfdisk;
      path = "bin/sgdisk";
    }
    {
      bin = "hexdump";
      pkg = pkgs.util-linux;
      path = "bin/hexdump";
    }
    {
      bin = "lsblk";
      pkg = pkgs.util-linux;
      path = "bin/lsblk";
    }
    {
      bin = "blkid";
      pkg = pkgs.util-linux;
      path = "bin/blkid";
    }
    {
      bin = "partx";
      pkg = pkgs.util-linux;
      path = "bin/partx";
    }
    {
      bin = "fdisk";
      pkg = pkgs.util-linux;
      path = "bin/fdisk";
    }

    # --─ Kernel module introspection (for ZFS troubleshooting) ─────────────────────
    {
      bin = "modinfo";
      pkg = pkgs.kmod;
      path = "bin/modinfo";
    }

    # ── ZFS ──────────────────────────────────────────────────────────────────
    {
      bin = "zdb";
      pkg = pkgs.zfs;
      path = "bin/zdb";
    }

    # ── Terminal ─────────────────────────────────────────────────────────────
    {
      bin = "tput";
      pkg = pkgs.ncurses;
      path = "bin/tput";
    }
    {
      bin = "reset";
      pkg = pkgs.ncurses;
      path = "bin/reset";
    }
    {
      bin = "infocmp";
      pkg = pkgs.ncurses;
      path = "bin/infocmp";
    }
  ];

  # resize: fix terminal geometry after socat/serial attach.
  # Implemented as a shell script to avoid pulling xterm's X11 deps into the initrd.
  # Uses ANSI CSI 18t (report terminal size) — works on any VT100-compatible terminal.
  resizeScript = pkgs.writeShellScriptBin "resize" ''
    old=$(stty -g 2>/dev/null || true)
    stty raw -echo min 0 time 5 2>/dev/null || true
    printf '\033[18t' >/dev/tty
    IFS=';t' read -r _ rows cols _ </dev/tty
    [ -n "$old" ] && stty "$old" 2>/dev/null || true
    [ -n "$rows" ] && [ -n "$cols" ] || { rows=24; cols=80; }
    printf 'COLUMNS=%d;\nLINES=%d;\nexport COLUMNS LINES;\n' "$cols" "$rows"
  '';

  extraBin =
    builtins.listToAttrs (
      map (e: {
        name = e.bin;
        value = "${e.pkg}/${e.path}";
      }) entries
    )
    // {
      resize = "${resizeScript}/bin/resize";
    };

  # storePaths must list specific binary paths, not whole package derivations.
  # make-initrd-ng traces ELF rpaths from each listed path — this is how shared
  # library deps (glibc, pcre2, etc.) get embedded in the initrd cpio.
  storePaths = pkgs.lib.unique (map (e: "${e.pkg}/${e.path}") entries) ++ [ resizeScript ];

  # packages: deduplicated package derivations for use with lib.makeBinPath.
  # Used by bringup-zfs-disk-image.nix to build the bringup shell PATH.
  packages = pkgs.lib.unique (map (e: e.pkg) entries) ++ [ resizeScript ];
in
{
  inherit extraBin storePaths packages;
}
