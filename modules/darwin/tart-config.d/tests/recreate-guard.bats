#!/usr/bin/env bats
# tart:vm:recreate's guard, on the real activation.sh's top-level functions (sourced, main not run), against a stub
# diskutil: a VM is recreated (its directory, data disks included, removed) only when every data disk is absent or
# provably blank. A disk holding ZFS, or one whose partition table cannot be read, refuses before anything is removed.

setup() {
  T="$BATS_TEST_TMPDIR"
  mkdir -p "$T/bin" "$T/vm"
  # The stubs: `diskutil image info --plist <img>` answers what <img>.kind says it holds (zfs | solaris | blank;
  # anything else fails, as an image held open by a running VM does), already as the JSON plutil would make of it;
  # the plutil stub passes it through. The real info:json and its « Image Format » test run unchanged.
  cat >"$T/bin/diskutil" <<STUB
#!$BASH
img=\$4
case "\$(cat "\$img.kind" 2>/dev/null)" in
  zfs) hint=ZFS ;;
  solaris) hint=Solaris_Root ;;
  blank) hint="" ;;
  *) exit 1 ;;
esac
printf '{"Image Format":"ASIF","Partitions":[{"content-hint":"%s"}]}\n' "\$hint"
STUB
  printf '#!%s\ncat\n' "$BASH" >"$T/bin/plutil"
  chmod +x "$T/bin/diskutil" "$T/bin/plutil"
  disk() { # <name> <kind>: a data disk image and what the stub says it holds
    : >"$T/vm/$1.img"
    printf '%s' "$2" >"$T/vm/$1.img.kind"
  }
  # The guard, sourced from the real script without running it (its last line runs main only when executed).
  sed "s#@nixBashTrampoline@#/dev/null#" "$BATS_TEST_DIRNAME/../activation.sh" >"$T/activation.sh"
  guard() {
    PATH="$T/bin:$PATH" bash -c 'set -euo pipefail; source "$1"; diskutil_bin="$2"; shift 2; tart:vm:recreate:guard "$@"' \
      _ "$T/activation.sh" "$T/bin/diskutil" "$@"
  }
}

@test "a live layout, every data disk holding ZFS, refuses, naming the disk, and removes nothing" {
  disk tank1 zfs
  disk tank2 zfs
  run guard "$T/vm/tank1.img" "$T/vm/tank2.img"
  [ "$status" -eq 1 ]
  [[ $output == *"REFUSED to recreate the VM: data disk $T/vm/tank1.img holds a ZFS pool"* ]]
  [[ $output == *"Nothing was stopped, deleted or removed"* ]]
  [ -e "$T/vm/tank1.img" ] && [ -e "$T/vm/tank2.img" ]
}

@test "one ZFS disk among blank ones is enough to refuse" {
  disk tank1 blank
  disk tank2 zfs
  run guard "$T/vm/tank1.img" "$T/vm/tank2.img"
  [ "$status" -eq 1 ]
  [[ $output == *"$T/vm/tank2.img holds a ZFS pool"* ]]
}

@test "a Solaris partition hint counts as ZFS" {
  disk tank1 solaris
  run guard "$T/vm/tank1.img"
  [ "$status" -eq 1 ]
}

@test "a disk whose partition table cannot be read refuses: not being able to look is not « nothing there »" {
  disk tank1 unreadable
  run guard "$T/vm/tank1.img"
  [ "$status" -eq 1 ]
  [[ $output == *"cannot tell whether data disk $T/vm/tank1.img holds a ZFS pool"* ]]
}

@test "a fresh host, its data disks blank or absent, may be recreated" {
  disk tank1 blank
  run guard "$T/vm/tank1.img" "$T/vm/tank2.img" "$T/vm/tank3.img"
  [ "$status" -eq 0 ]
  run guard
  [ "$status" -eq 0 ]
}

# tart:vm:recreate itself, extracted from main (where it is nested) as written, with a recording stub tart: on a
# live layout it refuses before ANY tart call, and the VM directory with its data disks is still there.
recreate() { # <expect: refuse|go> runs tart:vm:recreate on $T/home/.tart/vms/vm with $T/vm's disks as data disks
  mkdir -p "$T/home/.tart/vms/vm"
  cp "$T"/vm/*.img "$T"/vm/*.kind "$T/home/.tart/vms/vm/" 2>/dev/null || true
  printf '#!%s\nprintf "tart %%s\\n" "$*" >>"%s/calls"\nexit 0\n' "$BASH" "$T" >"$T/bin/tart"
  chmod +x "$T/bin/tart"
  sed -n '/^\ttart:vm:recreate() {/,/^\t}/p;/^\ttart:vm:run() {/,/^\t}/p;/^\ttart:vm:exists() {/,/^\t}/p' \
    "$BATS_TEST_DIRNAME/../activation.sh" >"$T/recreate.sh"
  # The data disks the MANIFEST declares: $DECLARED (a subset of what is in the directory), all of them by default.
  PATH="$T/bin:$PATH" DECLARED="${DECLARED-*}" bash -c '
    set -euo pipefail
    source "$1"; source "$2"
    diskutil_bin="$3"; tart_bin="$4"; effective_home="$5"
    tart_vm_data_disks=()
    for d in $DECLARED; do [[ $d == "*" ]] && tart_vm_data_disks=("$5"/.tart/vms/vm/tank*.img) || tart_vm_data_disks+=("$5/.tart/vms/vm/$d.img"); done
    tart:vm:recreate vm 64 asif' _ "$T/activation.sh" "$T/recreate.sh" "$T/bin/diskutil" "$T/bin/tart" "$T/home"
}

@test "tart:vm:recreate on a live layout refuses before any tart call, and the VM directory and its disks remain" {
  disk tank1 zfs
  disk tank2 zfs
  rm -f "$T/calls"
  run recreate
  [ "$status" -eq 1 ]
  [[ $output == *"REFUSED to recreate the VM"* ]]
  [ ! -e "$T/calls" ]
  [ -e "$T/home/.tart/vms/vm/tank1.img" ] && [ -e "$T/home/.tart/vms/vm/tank2.img" ]
}

@test "a ZFS disk in the VM directory that the manifest no longer declares is still probed: refused, nothing removed" {
  disk tank1 blank
  disk old-tank zfs
  rm -f "$T/calls"
  DECLARED=tank1 run recreate
  [ "$status" -eq 1 ]
  [[ $output == *"old-tank.img holds a ZFS pool"* ]]
  [ ! -e "$T/calls" ]
  [ -e "$T/home/.tart/vms/vm/old-tank.img" ]
}

@test "only the root disk itself is spared: a ZFS data disk whose NAME contains « disk » is still probed" {
  disk tank1 blank
  disk data-disk-2 zfs
  rm -f "$T/calls"
  run recreate
  [ "$status" -eq 1 ]
  [[ $output == *"data-disk-2.img holds a ZFS pool"* ]]
  [ ! -e "$T/calls" ]
}

@test "the root disk is not probed: recreate is what replaces a missing or unreadable one" {
  disk tank1 blank
  disk disk unreadable
  rm -f "$T/calls"
  run recreate
  [ "$status" -eq 0 ]
  grep -q '^tart create vm' "$T/calls"
}

@test "tart:vm:recreate on a fresh layout goes through: stop, create, the directory recreated" {
  disk tank1 blank
  rm -f "$T/calls"
  run recreate
  [ "$status" -eq 0 ]
  grep -q '^tart stop vm' "$T/calls"
  grep -q '^tart create vm --linux --disk-size 64 --disk-format asif' "$T/calls"
  [ ! -e "$T/home/.tart/vms/vm/tank1.img" ]
}

@test "the guard runs FIRST in tart:vm:recreate, before the stop, the delete and the rm -rf" {
  body=$(sed -n '/^\ttart:vm:recreate() {/,/^\t}/p' "$BATS_TEST_DIRNAME/../activation.sh")
  guard_line=$(grep -n 'tart:vm:recreate:guard' <<<"$body" | cut -d: -f1)
  for step in 'tart:vm:run stop "$vm"' 'tart:vm:run delete "$vm"' 'rm -rf "$vm_dir"'; do
    step_line=$(grep -nF -- "$step" <<<"$body" | head -1 | cut -d: -f1)
    if [ -z "$guard_line" ] || [ -z "$step_line" ] || [ "$guard_line" -ge "$step_line" ]; then
      echo "the guard is not before « $step »" >&2
      return 1
    fi
  done
  grep -q 'tart:vm:recreate:guard "\${present\[@\]}" || exit 1' <<<"$body"
}

# The VM directory is removed in exactly two places: recreate (automatic, guarded) and the factory reset, an EXPLICIT
# request whose purpose is to destroy the pool and which therefore stays unguarded. Any third one is a path this suite
# does not know.
@test "the VM directory is removed only by recreate (guarded) and by the explicit factory reset" {
  a="$BATS_TEST_DIRNAME/../activation.sh"
  [ "$(grep -c 'rm -rf "\$vm_dir"' "$a")" = 1 ]
  [ "$(grep -c 'rm -rf "${effective_home}/.tart/vms/' "$a")" = 0 ]
  [ "$(grep -c 'rm -rf "\$tart_vm_dir"' "$a")" = 1 ]
  reset=$(sed -n '/^\ttart:vm:factory-reset:apply() {/,/^\t}/p' "$a")
  grep -q 'rm -rf "\$tart_vm_dir"' <<<"$reset"
  grep -q 'if ! \$factory_reset; then' <<<"$reset"
}
