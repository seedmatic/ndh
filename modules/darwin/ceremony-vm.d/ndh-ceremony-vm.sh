# ndh-ceremony-vm <in-dir> <out-dir> — run the seedmatic root's ceremony VM on this Mac (docs/root-ceremony.adoc).
# The header sets qemu, kernel, initrd, init and params (the VM's kernel command line).
#
# The VM gets NO network device (-nodefaults -nic none), no shared folder, no option from the environment: its
# argv is fixed here. in-dir is copied onto a read-only vfat image (/ceremony/in), an empty vfat image becomes
# /ceremony/out; when the VM powers off, out is copied to out-dir, both images are deleted, and the destruction
# is checked and logged.

die() {
  printf '[ndh-ceremony-vm] ERROR: %s\n' "$*" >&2
  exit 1
}

(($# == 2)) || die "usage: ndh-ceremony-vm <in-dir> <out-dir>"
inDir="$1" outDir="$2"
[[ -d $inDir ]] || die "${inDir} is not a directory"
[[ ! -e $outDir ]] || die "${outDir} exists: the ceremony writes a new one"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
truncate -s 64M "$work/in.img" "$work/out.img"
mformat -i "$work/in.img" -v CEREMONYIN ::
mformat -i "$work/out.img" -v CEREMONYOUT ::
shopt -s nullglob dotglob
inputs=("$inDir"/*)
((${#inputs[@]})) && mcopy -i "$work/in.img" -s "${inputs[@]}" ::/

"$qemu" -nodefaults -nic none -machine virt,accel=hvf -cpu host -smp 2 -m 2048 \
  -kernel "$kernel" -initrd "$initrd" -append "init=${init} ${params}" \
  -drive "file=${work}/in.img,if=virtio,format=raw,readonly=on" \
  -drive "file=${work}/out.img,if=virtio,format=raw" \
  -serial stdio -monitor none -display none

mkdir -p "$outDir"
mcopy -i "$work/out.img" -s -n '::/*' "$outDir/"
rm -rf "$work"
trap - EXIT
[[ ! -e $work ]] || die "${work} is still there: delete it by hand before anything else"
if /usr/bin/pgrep -f -- "$work" >/dev/null; then die "a process still names ${work}: the VM is not gone"; fi
if [[ -f $outDir/ceremony.log ]]; then
  sed -i "s|^vm destroyed: .*|vm destroyed: $(date -u +%FT%TZ), images and work dir removed, no process left|" \
    "$outDir/ceremony.log"
fi
printf '[ndh-ceremony-vm] done: the outputs are in %s; the VM, its images and its work dir are gone\n' "$outDir" >&2
