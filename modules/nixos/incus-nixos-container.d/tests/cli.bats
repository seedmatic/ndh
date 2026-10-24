#!/usr/bin/env bats
#
# ndh-incus-container with incus, zfs, systemctl and nix stubbed: run as `ssh host sudo …` runs it, stdin an OPEN
# pipe, no incus call may wait on stdin (live, 2026-10-18: `incus project create` and `incus init` hung
# there for a YAML). The incus stub waits for stdin a moment and fails if the wait times out; its `start`
# fails if a store device's mount point is missing, as an unprivileged LXC does (EPERM, live, same day).

bats_require_minimum_version 1.5.0

setup() {
  t=$BATS_TEST_TMPDIR
  mkdir -p "$t/bin"
  # Instances: $t/inst/<name> holds its member (`none` on a standalone Incus), <name>.running that it runs; the cluster
  # is enabled when $t/clustered exists. Instance names are unique across the cluster, so another member's instance is
  # one of these files too.
  mkdir -p "$t/inst"
  cat >"$t/bin/incus" <<EOF
#!$BASH
printf 'incus %s\n' "\$*" >>"$t/calls"
# A read that times out (status > 128) means stdin was left open: the real incus would hang there.
read -r -t 2 _
if [ \$? -gt 128 ]; then echo "incus \$* waited on stdin" >&2; exit 99; fi
i=$t/inst
# The instance an argument list names: the first word that is neither an option nor an option's value.
name() {
  while [ \$# -gt 0 ]; do
    case "\$1" in
      --project|--storage|--target|-c) shift 2 ;;
      --*) shift ;;
      *) echo "\$1"; return ;;
    esac
  done
}
case "\$1 \$2" in
  "query /1.0/cluster") if [ -e "$t/clustered" ]; then echo '{"enabled": true}'; else echo '{"enabled": false}'; fi ;;
  "query /1.0/instances/"*)
    n=\${2#/1.0/instances/}; n=\${n%%\?*}; n=\${n%/state}
    [ -e "\$i/\$n" ] || { echo "Error: Instance not found" >&2; exit 1; }
    if [[ \$2 == */state\?* ]]; then
      if [ -e "\$i/\$n.running" ]; then echo '{"status": "Running"}'; else echo '{"status": "Stopped"}'; fi
    else
      printf '{"location": "%s"}\n' "\$(cat "\$i/\$n")"
    fi ;;
  "project show") exit 1 ;;
  "info --project") [ -e "\$i/\$(name "\${@:2}")" ] ;;
  "start --project")
    n=\$(name "\${@:2}")
    for m in nix/.lower/nix/store nix/.lower/nix/var/nix nix/.upper; do
      [ -d "$t/\$n/root/\$m" ] || { echo "incus start: mkdir \$m: EPERM" >&2; exit 98; }
    done
    touch "\$i/\$n.running"
    # A test's stand-in for what the new system does on its first start (a data migration).
    [ ! -x "$t/on-start" ] || "$t/on-start" ;;
  "stop --project" | "stop --force") rm -f "\$i/\$(name "\${@:2}").running" ;;
  # init: the instance on its --target (none on a standalone Incus); delete removes it.
  "init --empty")
    n=\$(name "\${@:2}") m=none
    for ((k = 1; k <= \$#; k++)); do [ "\${!k}" != --target ] || { k=\$((k + 1)); m=\${!k}; }; done
    [ ! -e "\$i/\$n" ] || { echo "incus init: \$n already exists" >&2; exit 1; }
    echo "\$m" >"\$i/\$n" ;;
  "delete --force") n=\$(name "\${@:2}"); rm -f "\$i/\$n" "\$i/\$n.running" ;;
  "rename --project")
    [ ! -e "$t/incus-rename-fails" ] || { echo "incus rename: failing" >&2; exit 1; }
    o=\$4 n=\$5
    [ -e "\$i/\$o" ] && [ ! -e "\$i/\$n" ] || { echo "incus rename: \$o → \$n refused" >&2; exit 1; }
    mv "\$i/\$o" "\$i/\$n"; [ ! -e "\$i/\$o.running" ] || mv "\$i/\$o.running" "\$i/\$n.running" ;;
  "exec --project")
    # Before activation the guest has no systemctl: no-systemctl holds how many probes it still lasts.
    if [ "\$7" = --version ]; then
      n=\$(cat "$t/no-systemctl" 2>/dev/null || echo 0)
      if [ "\$n" -gt 0 ]; then echo \$((n - 1)) >"$t/no-systemctl"; echo "Error: Command not found" >&2; exit 1; fi
      exit 0
    fi
    if [ "\$(cat "$t/no-systemctl" 2>/dev/null || echo 0)" -gt 0 ]; then echo "Error: Command not found" >&2; exit 1; fi
    unit="\${@: -1}"
    line=\$(grep "^\$unit " "$t/units" 2>/dev/null || true)
    if [ "\$7" = is-active ]; then
      state=\$(cut -d' ' -f2 <<<"\${line:-x active}")
      echo "\$state"
      [ "\$state" = active ]
    else
      cut -d' ' -f3 <<<"\$line"
    fi ;;
esac
EOF
  # Records every call. The state dataset tank/nerd/attic, tank/x and tank/db (the store's upper and nerd-nixos's DB) are
  # MODELLED, so a rollback and a commit can be checked on what is left: a dataset is a directory under $t/zfs, a
  # snapshot a copy of it beside, a rollback that copy put back. A snapshot still mounted under .zfs/snapshot (a line
  # in $t/mounts) is busy, and its destroy refused, as ZFS refuses it. As ZFS does, a rollback past newer snapshots
  # refuses without -r and destroys them with it: each snapshot records its creation order in $t/zfs/order.
  mkdir -p "$t/zfs/tank/nerd/attic" "$t/zfs/tank/x" "$t/zfs/tank/db"
  touch "$t/mounts"
  # The real cp, by its path: $t/bin/cp below stands for deliver's DB copy and copies nothing.
  realcp=$(command -v cp)
  cat >"$t/bin/zfs" <<EOF
#!$BASH
printf 'zfs %s\n' "\$*" >>"$t/calls"
z=$t/zfs
args=("\$@")
case "\$1" in
  snapshot)
    for a in "\${args[@]:1}"; do
      [ "\$a" != -r ] || continue
      ds=\${a%@*} snap=\${a#*@}
      [ -d "\$z/\$ds" ] || continue
      rm -rf "\$z/\$ds@\$snap"; $realcp -a "\$z/\$ds" "\$z/\$ds@\$snap"
      echo "\$ds@\$snap" >>"\$z/order"
    done ;;
  rollback)
    [ ! -e "$t/zfs-rollback-fails" ] || { echo "zfs rollback: failing" >&2; exit 1; }
    a=\${args[-1]}; ds=\${a%@*} snap=\${a#*@}
    [ -d "\$z/\$ds@\$snap" ] || { echo "zfs rollback: no snapshot \$a" >&2; exit 1; }
    # The snapshots of ds taken after this one and not destroyed since.
    newer=\$(sed -n "\\|^\$a\$|,\\\$p" "\$z/order" | tail -n +2 | grep "^\$ds@" | while read -r n; do [ ! -d "\$z/\$n" ] || echo "\$n"; done || true)
    if [ -n "\$newer" ]; then
      [ "\$2" = -r ] || { echo "zfs rollback: more recent snapshots exist; use '-r' to force deletion of: \$newer" >&2; exit 1; }
      for n in \$newer; do rm -rf "\$z/\$n"; done
    fi
    rm -rf "\$z/\$ds"; $realcp -a "\$z/\$ds@\$snap" "\$z/\$ds" ;;
  # create -p -o mountpoint=<dir> … <ds>: the dataset, mounted at its dir.
  create)
    ds=\${args[-1]} mp=
    for a in "\${args[@]}"; do [[ \$a != mountpoint=* ]] || mp=\${a#mountpoint=}; done
    mkdir -p "\$z/\$ds"
    [ -z "\$mp" ] || { mkdir -p "\$mp"; echo "\$mp" >"\$z/\$ds.mountpoint"; } ;;
  # A dataset rename moves its directory and its snapshots; a snapshot rename stays on its dataset, as ZFS has it.
  rename)
    [ ! -e "$t/zfs-rename-fails" ] || { echo "zfs rename: failing" >&2; exit 1; }
    o=\${args[1]} n=\${args[2]}
    [ -d "\$z/\$o" ] && [ ! -e "\$z/\$n" ] || { echo "cannot rename \$o to \$n" >&2; exit 1; }
    if [[ \$o == *@* ]]; then
      [ "\${o%@*}" = "\${n%@*}" ] || { echo "cannot rename \$o: snapshots stay on their dataset" >&2; exit 1; }
      mv "\$z/\$o" "\$z/\$n"
    else
      mv "\$z/\$o" "\$z/\$n"
      [ ! -e "\$z/\$o.mountpoint" ] || mv "\$z/\$o.mountpoint" "\$z/\$n.mountpoint"
      for s in "\$z/\$o"@*; do [ ! -d "\$s" ] || mv "\$s" "\$z/\$n@\${s##*@}"; done
    fi ;;
  # A dataset whose mountpoint is set moves its mounted tree there, as ZFS remounts it: <ds>.mountpoint holds where.
  set)
    # zfs-set-fails holds how many sets still fail.
    f=\$(cat "$t/zfs-set-fails" 2>/dev/null || echo 0)
    if [ "\$f" -gt 0 ]; then echo \$((f - 1)) >"$t/zfs-set-fails"; echo "zfs set: failing" >&2; exit 1; fi
    v=\${args[1]#mountpoint=} ds=\${args[2]}
    if [ "\${args[1]}" != "\$v" ] && [ -e "\$z/\$ds.mountpoint" ]; then
      cur=\$(cat "\$z/\$ds.mountpoint")
      [ "\$cur" = "\$v" ] || { [ ! -e "\$cur" ] || mv "\$cur" "\$v"; }
      echo "\$v" >"\$z/\$ds.mountpoint"
    fi ;;
  destroy)
    a=\${args[-1]}
    if [[ \$a != *@* ]]; then
      rm -rf "\$z/\$a" "\$z/\$a.mountpoint" "\$z/\$a"@*; exit 0
    fi
    if grep -q "/.zfs/snapshot/\${a#*@}\$" "$t/mounts"; then
      echo "cannot destroy snapshot \$a: dataset is busy" >&2; exit 1
    fi
    rm -rf "\$z/\$a" ;;
  list)
    found=0
    for a in "\${args[@]:1}"; do
      [ "\${a#-}" = "\$a" ] || continue
      case "\$a" in H|snapshot|name|filesystem) continue ;; esac
      [ -d "\$z/\$a" ] || continue
      found=1
      if [[ " \$* " == *" snapshot "* ]]; then
        for s in "\$z/\$a"@*; do [ -d "\$s" ] && echo "\$a@\${s##*@}"; done
      else
        echo "\$a"
      fi
    done
    [ "\$found" = 1 ] ;;
esac
EOF
  # findmnt -rn -o TARGET lists $t/mounts; -no FSTYPE|SOURCE answers for the store's upper and the DB.
  cat >"$t/bin/findmnt" <<EOF
#!$BASH
case "\$*" in *"-o TARGET"*) cat "$t/mounts"; exit 0 ;; esac
case "\$2 \$3" in "FSTYPE "*) echo zfs ;; "SOURCE /nix/var/nix/db") echo tank/db ;; "SOURCE "*) echo tank/x ;; esac
EOF
  cat >"$t/bin/umount" <<EOF
#!$BASH
printf 'umount %s\\n' "\$*" >>"$t/calls"
[ ! -e "$t/umount-fails" ] || exit 1
grep -vxF -- "\$1" "$t/mounts" >"$t/mounts.new" || true
mv "$t/mounts.new" "$t/mounts"
# A reader that comes back between the umount and the destroy: the automount is taken again, once.
if [ -e "$t/remount-once" ]; then rm "$t/remount-once"; echo "\$1" >>"$t/mounts"; fi
EOF
  # deliver copies the host DB's snapshot from a fixed path; the copy stands for it.
  cat >"$t/bin/cp" <<EOF
#!$BASH
mkdir -p "\${@: -1}"
EOF
  # The sandbox owns nothing as root: stat says 0 except for a path listed in foreign.
  cat >"$t/bin/stat" <<EOF
#!$BASH
if grep -qxF "\${@: -1}" "$t/foreign" 2>/dev/null; then echo 1000; else echo 0; fi
EOF
  # `date +%s` for the health deadline (a fixed clock: the timeout is HEALTH_TIMEOUT polls of sleep's
  # stub, which advances it), anything else the snapshot's timestamp.
  cat >"$t/bin/date" <<EOF
#!$BASH
if [ "\$1" = +%s ]; then cat "$t/clock" 2>/dev/null || echo 1000; else echo 20261018T000000Z; fi
EOF
  cat >"$t/bin/sleep" <<EOF
#!$BASH
c=\$(cat "$t/clock" 2>/dev/null || echo 1000); echo \$((c + \${1%.*})) >"$t/clock"
EOF
  printf '#!%s\nexit 1\n' "$BASH" >"$t/bin/mountpoint"
  # nix-env --store S -p PROFILE --set TARGET: the profile becomes a link to TARGET, as nix makes it, and
  # like nix it makes no parent ("cannot read directory", live). nix-env-fails makes it fail for that profile.
  cat >"$t/bin/nix-env" <<EOF
#!$BASH
printf 'nix-env %s\n' "\$*" >>"$t/calls"
[ "\$4" != "\$(cat "$t/nix-env-fails" 2>/dev/null)" ] || { echo "nix-env: failing on \$4" >&2; exit 1; }
[ -d "\$(dirname "\$4")" ] || { echo "error: cannot read directory \"\$(dirname "\$4")\": No such file or directory" >&2; exit 1; }
ln -sfn "\$6" "\$4"
EOF
  # yq, failing on the expression that reads the profiles when yq-profiles-fails exists.
  realyq=$(command -v yq)
  cat >"$t/bin/yq" <<EOF
#!$BASH
if [ -e "$t/yq-profiles-fails" ] && [[ " \$* " == *".profiles"* ]]; then echo "yq: failing" >&2; exit 1; fi
exec $realyq "\$@"
EOF
  for c in systemctl nix; do printf '#!%s\nprintf "%s %%s\\n" "$*" >>%q\nexit 0\n' "$BASH" "$c" "$t/calls" >"$t/bin/$c"; done
  chmod +x "$t/bin/"*
  touch "$t/x-attic" "$t/x-attic-old" "$t/x-runtime"
  printf '{"upperRoot":"%s/rw","lowerdirs":["/nix/.erofs/0"]}' "$t" >"$t/layers.json"
  # The CLI as replaceVars renders it (each value shell-quoted, as the module passes it; the trampoline raw), sourcing
  # the REAL trampoline and logger. NDH_TRAMPOLINE comes from the flake check.
  : "${NDH_TRAMPOLINE:?the ndh bash trampoline}"
  local -A vars=(
    [instances]='{"attic":{"name":"attic","target":null,"privileged":false,"dir":"'"$t"'/attic","dataset":"tank/nerd/ndh-containers/attic","toplevel":"'"$t"'/x-attic","hostStore":"local","devices":{},"profiles":{"/nix/var/nix/profiles/per-user/root/runtime":"'"$t"'/x-runtime"},"stateDatasets":["tank/nerd/attic"],"health":{"units":[{"unit":"atticd.service"},{"unit":"nginx.service","kind":"conditional"}]}}}'
    [project]=ndh [pool]=default [prestartHook]=/run/current-system/sw/bin/ndh-incus-container-prestart
    [layerContract]="$t/layers.json" [guestLower]=/nix/.lower [guestUpper]=/nix/.upper
    [stackDescription]="$t/stack.json" [storeDegraded]="$t/degraded" [gcroots]="$t/gcroots" [healthTimeout]=20
    [guestSystemctl]=/run/current-system/sw/bin/systemctl [nixConfig]="extra-experimental-features = nix-command"
    [logTag]=ndh.test.incusContainer
  )
  local text k
  text=$(cat "$BATS_TEST_DIRNAME/../cli.sh")
  text=${text//@nixBashTrampoline@/$NDH_TRAMPOLINE}
  for k in "${!vars[@]}"; do text=${text//@$k@/$(printf '%q' "${vars[$k]}")}; done
  cli=$t/ndh-incus-container
  printf '%s\n' "$text" >"$cli"
  run grep -c '@[a-zA-Z]*@' "$cli"
  [ "$output" = 0 ]
  # Run as the guest's unit runs it: by the store bash, through the trampoline, under the PATH it then has and nothing
  # of the sandbox's. The trampoline puts the bringup profile FIRST, then the system's sw (measured): so the test's
  # profile is the fixture's tools with this suite's stubs over them, and the system is coreutils, findutils and
  # util-linux. No bash of the caller's anywhere.
  mkdir -p "$t/profile/bin"
  for c in "$NDH_BOOTSTRAP_PROFILE_DIR"/bin/*; do ln -s "$c" "$t/profile/bin/"; done
  for c in "$t"/bin/*; do ln -sfn "$c" "$t/profile/bin/"; done
  # The logger's sink is the test's stderr (the guest's is the journal): the logger itself still tags every line.
  printf '#!%s\nexec cat >&2\n' "$BASH" >"$t/logger"
  chmod +x "$t/logger"
  cat >"$t/run" <<EOF
#!$BASH
exec env -i HOME="$t" NDH_BOOTSTRAP_PROFILE_DIR="$t/profile" LOGGER_CMD="$t/logger" \\
  PATH="$NDH_TEST_SYSTEM_SW/bin" "$BASH" "\$@"
EOF
  chmod +x "$t/run"
  # A pipe held open by a writer that never writes: what stdin is under `ssh host sudo …`.
  mkfifo "$t/stdin"
  sleep 60 >"$t/stdin" &
  holder=$!
}

teardown() { kill "$holder" 2>/dev/null || true; }

@test "create, stdin an open pipe as over ssh: no incus call waits on it" {
  run --separate-stderr "$t/run" "$cli" create attic <"$t/stdin"
  [ "$status" -eq 0 ]
  [[ $stderr != *"waited on stdin"* ]]
  grep -q '^incus project create ndh$' "$t/calls"
  grep -q '^incus init --empty --project ndh --storage default attic ' "$t/calls"
}

@test "deliver makes the store devices' mount points before the start, and waits on no stdin" {
  echo none >"$t/inst/attic"
  mkdir -p "$t/rw/.zfs/snapshot/ndh-incus-attic-20261018T000000Z/upper"
  run --separate-stderr "$t/run" "$cli" deliver attic <"$t/stdin"
  [ "$status" -eq 0 ]
  [[ $stderr != *"waited on stdin"* && $stderr != *EPERM* ]]
  grep -q '^incus start --project ndh attic$' "$t/calls"
}

@test "deliver refuses a symlink on a mount point's path: nothing snapshotted, nothing created" {
  echo none >"$t/inst/attic"
  mkdir -p "$t/attic/root/nix" "$t/elsewhere"
  ln -s "$t/elsewhere" "$t/attic/root/nix/.lower"
  run --separate-stderr "$t/run" "$cli" deliver attic <"$t/stdin"
  [ "$status" -eq 1 ]
  [[ $stderr == *"root/nix/.lower is not root's own directory"* ]]
  [ -z "$(ls -A "$t/elsewhere")" ]
  run grep -E '^(zfs snapshot|incus start)' "$t/calls"
  [ "$status" -eq 1 ]
}

@test "deliver refuses a component another uid owns: nothing snapshotted, nothing created" {
  echo none >"$t/inst/attic"
  mkdir -p "$t/attic/root/nix"
  echo "$t/attic/root/nix" >"$t/foreign"
  run --separate-stderr "$t/run" "$cli" deliver attic <"$t/stdin"
  [ "$status" -eq 1 ]
  [[ $stderr == *"root/nix is not root's own directory"* ]]
  [ ! -e "$t/attic/root/nix/.lower" ]
  run grep -E '^(zfs snapshot|incus start)' "$t/calls"
  [ "$status" -eq 1 ]
}

@test "usage names the verbs" {
  run --separate-stderr "$t/run" "$cli"
  [ "$status" -eq 2 ]
  [[ $stderr == *"ndh-incus-container create"* && $stderr == *"ndh-incus-container deliver"* ]]
  [[ $stderr == *"ndh-incus-container converge"* ]]
}

# A container already delivered once on x-attic-old: a profile, a previous snapshot's stamp, an upper.
delivered_before() {
  echo none >"$t/inst/attic"
  mkdir -p "$t/attic/root/nix/var/nix/profiles" "$t/attic/upper" "$t/rw/.zfs/snapshot/ndh-incus-attic-20261018T000000Z/upper"
  ln -sfn "$t/x-attic-old" "$t/attic/root/nix/var/nix/profiles/system"
  echo ndh-incus-attic-20261001T000000Z >"$t/attic/lower.snapshot"
  echo old-upper >"$t/attic/upper/marker"
  echo schema-1 >"$t/zfs/tank/nerd/attic/db"
}

@test "converge on the declared system does nothing" {
  delivered_before
  ln -sfn "$t/x-attic" "$t/attic/root/nix/var/nix/profiles/system"
  mkdir -p "$t/attic/root/nix/var/nix/profiles/per-user/root"
  ln -sfn "$t/x-runtime" "$t/attic/root/nix/var/nix/profiles/per-user/root/runtime"
  run --separate-stderr "$t/run" "$cli" converge <"$t/stdin"
  [ "$status" -eq 0 ]
  [[ $output == *"attic holds its declared system and profiles"* ]]
  run grep -E '^(zfs snapshot|incus stop|incus start)' "$t/calls"
  [ "$status" -eq 1 ]
}

@test "converge delivers a changed system, sets its profiles host side, and keeps it when healthy" {
  delivered_before
  echo "nginx.service inactive no" >"$t/units"
  run --separate-stderr "$t/run" "$cli" converge <"$t/stdin"
  [ "$status" -eq 0 ]
  [[ $output == *"attic ← $t/x-attic, healthy"* ]]
  [ "$(readlink "$t/attic/root/nix/var/nix/profiles/system")" = "$t/x-attic" ]
  # The bringup profile, set host side, not by the container's activation.
  [ "$(readlink "$t/attic/root/nix/var/nix/profiles/per-user/root/runtime")" = "$t/x-runtime" ]
  # Committed: nothing kept aside, the previous delivery snapshot destroyed.
  [ -z "$(ls -d "$t/attic"/.previous-* 2>/dev/null)" ]
  [ ! -e "$t/attic/converge.failed" ]
}

@test "converge rolls back an unhealthy system exactly, fails loudly, and does not retry it" {
  delivered_before
  echo "atticd.service failed" >"$t/units"
  run --separate-stderr "$t/run" "$cli" converge <"$t/stdin"
  [ "$status" -eq 1 ]
  [[ $stderr == *"atticd.service is failed"* && $stderr == *"back on its previous system"* ]]
  # Back on the previous system, its upper and its stamp.
  [ "$(readlink "$t/attic/root/nix/var/nix/profiles/system")" = "$t/x-attic-old" ]
  [ "$(cat "$t/attic/upper/marker")" = old-upper ]
  [ "$(cat "$t/attic/lower.snapshot")" = ndh-incus-attic-20261001T000000Z ]
  grep -q '^zfs destroy tank/x@ndh-incus-attic-20261018T000000Z$' "$t/calls"
  [ "$(sed -n 2p "$t/attic/converge.failed")" = "/nix/var/nix/profiles/system	$t/x-attic" ]
  # Once per toplevel: the next converge does not deliver it again.
  : >"$t/calls"
  run --separate-stderr "$t/run" "$cli" converge <"$t/stdin"
  [ "$status" -eq 1 ]
  [[ $stderr == *"already failed on $t/x-attic"* ]]
  run grep -E '^(zfs snapshot|incus start)' "$t/calls"
  [ "$status" -eq 1 ]
}

@test "converge creates a declared container this standalone Incus does not have, then delivers it" {
  mkdir -p "$t/rw/.zfs/snapshot/ndh-incus-attic-20261018T000000Z/upper"
  run --separate-stderr "$t/run" "$cli" converge <"$t/stdin"
  [ "$status" -eq 0 ]
  [[ $output == *"attic created on this standalone member"* && $output == *"healthy"* ]]
  [ "$(cat "$t/inst/attic")" = none ]
  grep -q '^incus init --empty --project ndh --storage default attic ' "$t/calls"
}

@test "converge rolls the state dataset back too: a migration the new system made is undone" {
  delivered_before
  echo "atticd.service failed" >"$t/units"
  # The NEW system migrates its data on its first start, then turns out unhealthy; the previous system,
  # restarted by the rollback, does not migrate.
  printf '#!%s\n[ -e %q ] || { echo schema-2 >%q; touch %q; }\n' "$BASH" "$t/migrated" "$t/zfs/tank/nerd/attic/db" "$t/migrated" >"$t/on-start"
  chmod +x "$t/on-start"
  run --separate-stderr "$t/run" "$cli" converge <"$t/stdin"
  [ "$status" -eq 1 ]
  [ "$(cat "$t/zfs/tank/nerd/attic/db")" = schema-1 ]
  grep -q '^zfs snapshot -r tank/nerd/attic@ndh-incus-attic-20261018T000000Z$' "$t/calls"
  grep -q '^zfs rollback -r tank/nerd/attic@ndh-incus-attic-20261018T000000Z$' "$t/calls"
  # No snapshot of the state is left behind.
  [ -z "$(ls -d "$t/zfs/tank/nerd/attic@"* 2>/dev/null)" ]
}

@test "converge keeps the migrated state when healthy, and destroys its snapshot" {
  delivered_before
  printf '#!%s\necho schema-2 >%q\n' "$BASH" "$t/zfs/tank/nerd/attic/db" >"$t/on-start"
  chmod +x "$t/on-start"
  run --separate-stderr "$t/run" "$cli" converge <"$t/stdin"
  [ "$status" -eq 0 ]
  [ "$(cat "$t/zfs/tank/nerd/attic/db")" = schema-2 ]
  grep -q '^zfs destroy -r tank/nerd/attic@ndh-incus-attic-20261018T000000Z$' "$t/calls"
  [ -z "$(ls -d "$t/zfs/tank/nerd/attic@"* 2>/dev/null)" ]
}

@test "the state snapshot is taken with the container stopped, before anything is delivered" {
  delivered_before
  touch "$t/inst/attic.running"
  run --separate-stderr "$t/run" "$cli" converge <"$t/stdin"
  [ "$status" -eq 0 ]
  stop=$(grep -n '^incus stop --project ndh attic$' "$t/calls" | cut -d: -f1)
  snap=$(grep -n '^zfs snapshot -r tank/nerd/attic@' "$t/calls" | cut -d: -f1)
  start=$(grep -n '^incus start --project ndh attic$' "$t/calls" | head -1 | cut -d: -f1)
  [ -n "$stop" ]
  [ -n "$snap" ]
  [ -n "$start" ]
  [ "$stop" -lt "$snap" ]
  [ "$snap" -lt "$start" ]
}


@test "converge makes a profile's missing parent host side, root's own, and lands the profile" {
  delivered_before
  # The old /nix/var/nix, per-user/root with it, goes aside at delivery: nothing of the parent is left.
  [ ! -e "$t/attic/root/nix/var/nix/profiles/per-user" ]
  # A strict umask in the caller: the mode below is the CLI's doing.
  umask 077
  run --separate-stderr "$t/run" "$cli" converge <"$t/stdin"
  [ "$status" -eq 0 ]
  [ -d "$t/attic/root/nix/var/nix/profiles/per-user/root" ]
  [ "$(stat -c %a "$t/attic/root/nix/var/nix/profiles/per-user")" = 755 ]
  [ "$(stat -c %a "$t/attic/root/nix/var/nix/profiles/per-user/root")" = 755 ]
  [ "$(readlink "$t/attic/root/nix/var/nix/profiles/per-user/root/runtime")" = "$t/x-runtime" ]
}

@test "mutant: without the parent's mkdir, the delivery fails and rolls back, never healthy" {
  delivered_before
  grep -q '^    (umask 022 && mkdir -p "\$dir/root/\$parent")$' "$cli"
  sed '/^    (umask 022 && mkdir -p "\$dir\/root\/\$parent")$/d' "$cli" >"$t/mutant"
  run --separate-stderr "$t/run" "$t/mutant" converge <"$t/stdin"
  [ "$status" -eq 1 ]
  [[ $stderr == *"cannot read directory"* ]]
  [[ $output != *healthy* ]]
  [ "$(readlink "$t/attic/root/nix/var/nix/profiles/system")" = "$t/x-attic-old" ]
}

@test "a nix-env failure on a profile fails the delivery, rolls back, and is not retried" {
  delivered_before
  echo "$t/attic/root/nix/var/nix/profiles/per-user/root/runtime" >"$t/nix-env-fails"
  run --separate-stderr "$t/run" "$cli" converge <"$t/stdin"
  [ "$status" -eq 1 ]
  [[ $stderr == *"could not be delivered"* && $stderr == *"back on its previous system"* ]]
  [[ $output != *healthy* ]]
  [ "$(readlink "$t/attic/root/nix/var/nix/profiles/system")" = "$t/x-attic-old" ]
  [ "$(cat "$t/attic/upper/marker")" = old-upper ]
  [ "$(cat "$t/attic/lower.snapshot")" = ndh-incus-attic-20261001T000000Z ]
  [ -z "$(ls -d "$t/attic"/.previous-* 2>/dev/null)" ]
  [ "$(sed -n 2p "$t/attic/converge.failed")" = "/nix/var/nix/profiles/system	$t/x-attic" ]
}

@test "mutant: the delivery steps in the caller's process lose the nix-env failure" {
  delivered_before
  echo "$t/attic/root/nix/var/nix/profiles/per-user/root/runtime" >"$t/nix-env-fails"
  grep -q '"\$BASH" "\${BASH_SOURCE\[0\]}" _deliver-steps "\$1"' "$cli"
  # The postcondition goes too, so only the process boundary stands between the failure and "healthy".
  sed -e 's/"\$BASH" "\${BASH_SOURCE\[0\]}" _deliver-steps "\$1"/deliver_steps "$1"/' \
    -e '/^  declared_ok "\$1" >&2 || die/d' "$cli" >"$t/mutant"
  run grep -q 'declared_ok "\$1" >&2' "$t/mutant"
  [ "$status" -eq 1 ]
  run --separate-stderr "$t/run" "$t/mutant" converge <"$t/stdin"
  [[ $output == *healthy* ]]
}

@test "a yq failure reading the profiles fails converge loudly, and delivers nothing" {
  delivered_before
  touch "$t/yq-profiles-fails"
  run --separate-stderr "$t/run" "$cli" converge <"$t/stdin"
  [ "$status" -eq 1 ]
  [[ $stderr == *"declared profiles could not be read"* ]]
  [[ $output != *healthy* ]]
  [ "$(readlink "$t/attic/root/nix/var/nix/profiles/system")" = "$t/x-attic-old" ]
  run grep -E '^(zfs snapshot|incus start)' "$t/calls"
  [ "$status" -eq 1 ]
}

@test "mutant: a profiles read whose yq status is lost passes as healthy" {
  delivered_before
  touch "$t/yq-profiles-fails"
  grep -q '^  profiles=\$(yq .*<<<"\$1") || return 1$' "$cli"
  sed 's/^\(  profiles=\$(yq .*<<<"\$1")\) || return 1$/\1 || true/' "$cli" >"$t/mutant"
  grep -q '<<<"\$1") || true$' "$t/mutant"
  run --separate-stderr "$t/run" "$t/mutant" converge <"$t/stdin"
  [[ $output == *healthy* ]]
}

@test "a profile that does not resolve to its declared package after nix-env fails the delivery" {
  delivered_before
  # nix-env "succeeds" but lands the profile elsewhere.
  printf '#!%s\nprintf "nix-env %%s\\n" "$*" >>%q\ncase "$4" in */per-user/*) ln -sfn %q "$4" ;; *) ln -sfn "$6" "$4" ;; esac\n' \
    "$BASH" "$t/calls" "$t/x-attic-old" >"$t/bin/nix-env"
  chmod +x "$t/bin/nix-env"
  run --separate-stderr "$t/run" "$cli" converge <"$t/stdin"
  [ "$status" -eq 1 ]
  [[ $stderr == *"per-user/root/runtime is not $t/x-runtime"* ]]
  [[ $stderr == *"does not hold its declared profiles after delivery"* ]]
}

@test "mutant: without the postcondition, a misplaced profile passes as healthy" {
  delivered_before
  printf '#!%s\nprintf "nix-env %%s\\n" "$*" >>%q\ncase "$4" in */per-user/*) ln -sfn %q "$4" ;; *) ln -sfn "$6" "$4" ;; esac\n' \
    "$BASH" "$t/calls" "$t/x-attic-old" >"$t/bin/nix-env"
  chmod +x "$t/bin/nix-env"
  grep -q '^  declared_ok "\$1" >&2 || die' "$cli"
  sed '/^  declared_ok "\$1" >&2 || die/d' "$cli" >"$t/mutant"
  run --separate-stderr "$t/run" "$t/mutant" converge <"$t/stdin"
  [[ $output == *healthy* ]]
}

@test "the health probes call the guest's systemctl by its path" {
  delivered_before
  run --separate-stderr "$t/run" "$cli" converge <"$t/stdin"
  [ "$status" -eq 0 ]
  grep -q -- '-- /run/current-system/sw/bin/systemctl is-active atticd.service$' "$t/calls"
  run grep -E -- '-- systemctl ' "$t/calls"
  [ "$status" -eq 1 ]
}

@test "a rollback whose step fails says it needs a hand, and never claims it rolled back" {
  delivered_before
  echo "atticd.service failed" >"$t/units"
  touch "$t/zfs-rollback-fails"
  run --separate-stderr "$t/run" "$cli" converge <"$t/stdin"
  [ "$status" -eq 1 ]
  [[ $stderr == *"zfs rollback: failing"* ]]
  [[ $stderr == *"rollback FAILED: it needs a hand"* ]]
  [[ $output != *"rolled back"* ]]
}

# A rollback refused on its arguments has touched nothing: no zfs call, no stop, the kept state in place.
refused_untouched() {
  run grep -E '^(zfs (rollback|destroy)|incus stop)' "$t/calls"
  [ "$status" -eq 1 ]
  [ -d "$t/attic/.previous-ndh-incus-attic-20261018T000000Z" ]
}

@test "_rollback refuses a snapshot that is not a delivery snapshot of this instance, and touches nothing" {
  delivered_before
  mkdir -p "$t/attic/.previous-ndh-incus-attic-20261018T000000Z" "$t/x"
  for snapshot in ../x a@b "" ndh-incus-other-20261018T000000Z ndh-incus-attic-20261018T000000Z/../../x \
    ndh-incus-attic-2026101T000000Z ndh-incus-attic-20261018T000000Z@x; do
    : >"$t/calls"
    run --separate-stderr "$t/run" "$cli" _rollback attic "$snapshot" <"$t/stdin"
    [ "$status" -ne 0 ]
    refused_untouched
  done
  [ -d "$t/x" ]
}

@test "mutant: without the snapshot check, a hostile name reaches zfs" {
  delivered_before
  mkdir -p "$t/attic/.previous-a@b"
  # The check dropped from rollback_steps alone, its call being the first line of it that names the snapshot.
  grep -q '^  delivery_snapshot "\$1" "\$2"$' "$cli"
  awk '/^rollback_steps\(\) \{/{r=1} r && /^  delivery_snapshot "\$1" "\$2"$/{r=0; next} {print}' "$cli" >"$t/mutant"
  [ "$(grep -c '^  delivery_snapshot "\$1" "\$2"$' "$t/mutant")" = 1 ]
  run --separate-stderr "$t/run" "$t/mutant" _rollback attic a@b <"$t/stdin"
  grep -qE '^(zfs (rollback|destroy)|incus stop)' "$t/calls"
}

@test "an instance name outside an Incus name's shape is refused before any use" {
  for name in ../attic 'att.c' 'attic;x' '' ATTIC; do
    : >"$t/calls"
    run --separate-stderr "$t/run" "$cli" _deliver-steps "$name" <"$t/stdin"
    [ "$status" -ne 0 ]
    run --separate-stderr "$t/run" "$cli" _rollback "$name" ndh-incus-attic-20261018T000000Z <"$t/stdin"
    [ "$status" -ne 0 ]
    [ ! -s "$t/calls" ]
  done
}

@test "a DECLARED name of the wrong shape is refused too, and the mutant without the check takes it" {
  # The declaration lookup alone would accept it: the shape check is what refuses it.
  # att.c declared as a copy of attic, right after the wrapper's INSTANCES line.
  sed '/^INSTANCES=/a INSTANCES=$(yq -p json -o json -I0 '"'"'.["att.c"] = .attic'"'"' <<<"$INSTANCES")' "$cli" >"$t/declared"
  [ "$(grep -c '"att.c"' "$t/declared")" = 1 ]
  run --separate-stderr "$t/run" "$t/declared" _deliver-steps 'att.c' <"$t/stdin"
  [ "$status" -ne 0 ]
  [[ $stderr == *"is not an instance name"* ]]
  sed '/is not an instance name/d' "$t/declared" >"$t/mutant"
  run --separate-stderr "$t/run" "$t/mutant" _deliver-steps 'att.c' <"$t/stdin"
  [[ $stderr != *"is not an instance name"* && $stderr != *"no instance 'att.c' is declared"* ]]
}

# What converge must leave TRUE, whatever it did to get there: every declared profile resolves to its package.
holds_declared() {
  [ "$(readlink -f "$t/attic/root/nix/var/nix/profiles/system")" = "$(readlink -f "$t/x-attic")" ]
  [ "$(readlink -f "$t/attic/root/nix/var/nix/profiles/per-user/root/runtime")" = "$(readlink -f "$t/x-runtime")" ]
}

# The system already the declared one: only the profiles differ.
system_current() {
  delivered_before
  ln -sfn "$t/x-attic" "$t/attic/root/nix/var/nix/profiles/system"
}

@test "the system matches but a declared profile is missing: converge delivers, and it then holds" {
  system_current
  run --separate-stderr "$t/run" "$cli" converge <"$t/stdin"
  [ "$status" -eq 0 ]
  [[ $stderr == *"per-user/root/runtime is not $t/x-runtime"* ]]
  holds_declared
}

@test "the system matches but a declared profile points elsewhere: converge delivers, and it then holds" {
  system_current
  mkdir -p "$t/attic/root/nix/var/nix/profiles/per-user/root"
  ln -sfn "$t/x-attic-old" "$t/attic/root/nix/var/nix/profiles/per-user/root/runtime"
  run --separate-stderr "$t/run" "$cli" converge <"$t/stdin"
  [ "$status" -eq 0 ]
  holds_declared
}

@test "mutant: an up-to-date test on the system alone leaves a missing profile missing" {
  system_current
  # Its shape before this fix: the system's profile only.
  grep -q 'if wrong=\$(declared_ok "\$name"); then' "$cli"
  sed 's|if wrong=\$(declared_ok "\$name"); then|if [ "$(readlink -f "$dir/root/nix/var/nix/profiles/system")" = "$(readlink -f "$toplevel")" ]; then|' "$cli" >"$t/mutant"
  run --separate-stderr "$t/run" "$t/mutant" converge <"$t/stdin"
  run holds_declared
  [ "$status" -ne 0 ]
}

@test "a profile changed alone, the system the same, is a new attempt after a failed one" {
  system_current
  echo "atticd.service failed" >"$t/units"
  run --separate-stderr "$t/run" "$cli" converge <"$t/stdin"
  [ "$status" -eq 1 ]
  # The same declared state: not retried.
  : >"$t/calls"
  run --separate-stderr "$t/run" "$cli" converge <"$t/stdin"
  [[ $stderr == *"already failed"* ]]
  # A new runtime declared, the system unchanged: a new attempt.
  touch "$t/x-runtime-2"
  sed '/^INSTANCES=/a INSTANCES=$(yq -p json -o json -I0 '"'"'.attic.profiles[] += "-2"'"'"' <<<"$INSTANCES")' "$cli" >"$t/cli-2"
  [ "$(grep -c 'x-runtime-2\|+= "-2"' "$t/cli-2")" = 1 ]
  : >"$t/units"
  run --separate-stderr "$t/run" "$t/cli-2" converge <"$t/stdin"
  [ "$status" -eq 0 ]
  [ "$(readlink -f "$t/attic/root/nix/var/nix/profiles/per-user/root/runtime")" = "$(readlink -f "$t/x-runtime-2")" ]
}

@test "under the trampoline the CLI resolves its tools from the profile, then the system, never the sandbox's" {
  # Measured inside the trampolined script: its first PATH entry is the profile, then the system's sw, and nothing
  # else (the live order). bash is the profile's, which the trampoline requires; the stubbed tools are the stand-ins.
  # `type -P`: the CLI wraps incus in a function of its own.
  sed 's/^ndh::logger:command:run .*/printf "%s\\n" "$PATH" "$(type -P bash)" "$(type -P incus)"/' "$cli" >"$t/probe"
  run --separate-stderr "$t/run" "$t/probe"
  [ "$status" -eq 0 ]
  [ "${lines[0]%%:*}" = "$t/profile/bin" ]
  [[ ${lines[0]} == *":$NDH_TEST_SYSTEM_SW/bin"* ]]
  [ "${lines[1]}" = "$t/profile/bin/bash" ]
  [ "${lines[2]}" = "$t/profile/bin/incus" ]
}

@test "a failure on the delivering tool is retried by the tool's next revision, the declared state the same" {
  delivered_before
  echo "atticd.service failed" >"$t/units"
  run --separate-stderr "$t/run" "$cli" converge <"$t/stdin"
  [ "$status" -eq 1 ]
  : >"$t/calls"
  run --separate-stderr "$t/run" "$cli" converge <"$t/stdin"
  [[ $stderr == *"already failed"* ]]
  # The same script at another path: a new revision of the tool, the containers' declared state unchanged.
  cp "$cli" "$t/ndh-incus-container-next"
  : >"$t/units"
  run --separate-stderr "$t/run" "$t/ndh-incus-container-next" converge <"$t/stdin"
  [ "$status" -eq 0 ]
  [[ $stderr != *"already failed"* ]]
  [[ $output == *healthy* ]]
}

@test "mutant: converge.failed without the tool keeps the next revision from retrying" {
  delivered_before
  echo "atticd.service failed" >"$t/units"
  grep -q "declared=\$(printf 'tool" "$cli"
  sed "/declared=\$(printf 'tool/d" "$cli" >"$t/mutant"
  run --separate-stderr "$t/run" "$t/mutant" converge <"$t/stdin"
  cp "$t/mutant" "$t/mutant-next"
  : >"$t/units"
  run --separate-stderr "$t/run" "$t/mutant-next" converge <"$t/stdin"
  [[ $stderr == *"already failed"* ]]
}

# The state bioskop-nixos was left in on 2026-10-22: attic delivered and healthy on 184302Z, its profiles declared,
# and the commit died on a busy snapshot, so the previous delivery's pair (145633Z), the aside and the state snapshot of
# 184302Z are still there, and so is a converge.failed from before.
left_by_a_dead_commit() {
  echo none >"$t/inst/attic"
  touch "$t/inst/attic.running"
  mkdir -p "$t/attic/root/nix/var/nix/profiles/per-user/root" "$t/attic/.previous-ndh-incus-attic-20261022T184302Z"
  ln -sfn "$t/x-attic" "$t/attic/root/nix/var/nix/profiles/system"
  ln -sfn "$t/x-runtime" "$t/attic/root/nix/var/nix/profiles/per-user/root/runtime"
  echo ndh-incus-attic-20261022T184302Z >"$t/attic/lower.snapshot"
  for ds in tank/x tank/db; do
    mkdir -p "$t/zfs/$ds@ndh-incus-attic-20261022T145633Z" "$t/zfs/$ds@ndh-incus-attic-20261022T184302Z"
  done
  mkdir -p "$t/zfs/tank/nerd/attic@ndh-incus-attic-20261022T184302Z"
  printf 'tool\t/an/older/cli\n' >"$t/attic/converge.failed"
}

# Every delivery snapshot but the current one, every state snapshot and every aside: what a commit leaves none of.
no_leftovers() {
  [ -z "$(ls -d "$t/zfs/tank/x@"* "$t/zfs/tank/db@"* 2>/dev/null | grep -v '@ndh-incus-attic-20261022T184302Z$')" ]
  [ -d "$t/zfs/tank/x@ndh-incus-attic-20261022T184302Z" ]
  [ -d "$t/zfs/tank/db@ndh-incus-attic-20261022T184302Z" ]
  [ -z "$(ls -d "$t/zfs/tank/nerd/attic@"* 2>/dev/null)" ]
  [ -z "$(ls -d "$t/attic"/.previous-* 2>/dev/null)" ]
}

@test "converge finishes a commit that died, on today's exact leftovers, with no gesture" {
  left_by_a_dead_commit
  run --separate-stderr "$t/run" "$cli" converge <"$t/stdin"
  [ "$status" -eq 0 ]
  [[ $output == *"previous delivery committed"* ]]
  no_leftovers
  [ ! -e "$t/attic/converge.failed" ]
  # Nothing redelivered: the container already held its declared state.
  run grep -E '^(zfs snapshot|incus stop|incus start)' "$t/calls"
  [ "$status" -eq 1 ]
}

@test "a snapshot still automounted under .zfs/snapshot is unmounted, then destroyed" {
  left_by_a_dead_commit
  echo "/nix/.rw-store/.zfs/snapshot/ndh-incus-attic-20261022T145633Z" >"$t/mounts"
  run --separate-stderr "$t/run" "$cli" converge <"$t/stdin"
  [ "$status" -eq 0 ]
  grep -qxF 'umount /nix/.rw-store/.zfs/snapshot/ndh-incus-attic-20261022T145633Z' "$t/calls"
  no_leftovers
}

@test "mutant: without the umount, the busy snapshot stops the commit, and the next converge resumes it" {
  left_by_a_dead_commit
  echo "/nix/.rw-store/.zfs/snapshot/ndh-incus-attic-20261022T145633Z" >"$t/mounts"
  grep -q '      umount "\$target" || true' "$cli"
  sed '/      umount "\$target" || true/d' "$cli" >"$t/mutant"
  run --separate-stderr "$t/run" "$t/mutant" converge <"$t/stdin"
  [ "$status" -eq 1 ]
  [[ $stderr == *"dataset is busy"* && $stderr == *"next converge resumes it"* ]]
  [ -d "$t/attic/.previous-ndh-incus-attic-20261022T184302Z" ]
  # The automount expires; the next converge, even this one, finishes.
  : >"$t/mounts"
  run --separate-stderr "$t/run" "$t/mutant" converge <"$t/stdin"
  [ "$status" -eq 0 ]
  no_leftovers
}

@test "a commit that fails after a healthy delivery keeps the system, marks no failed attempt, and is resumed" {
  delivered_before
  # The previous delivery's snapshot, still automounted.
  for ds in tank/x tank/db; do mkdir -p "$t/zfs/$ds@ndh-incus-attic-20261001T000000Z"; done
  echo "/nix/.rw-store/.zfs/snapshot/ndh-incus-attic-20261001T000000Z" >"$t/mounts"
  touch "$t/umount-fails"
  run --separate-stderr "$t/run" "$cli" converge <"$t/stdin"
  [ "$status" -eq 1 ]
  [[ $output == *healthy* ]]
  [[ $stderr == *"commit is unfinished"* ]]
  [ "$(readlink "$t/attic/root/nix/var/nix/profiles/system")" = "$t/x-attic" ]
  [ ! -e "$t/attic/converge.failed" ]
  rm "$t/umount-fails"
  run --separate-stderr "$t/run" "$cli" converge <"$t/stdin"
  [ "$status" -eq 0 ]
  [[ $output == *"previous delivery committed"* ]]
  [ -z "$(ls -d "$t/zfs/tank/x@ndh-incus-attic-20261001T000000Z" 2>/dev/null)" ]
  [ -z "$(ls -d "$t/attic"/.previous-* 2>/dev/null)" ]
}

@test "leftovers are kept while the container is unhealthy: its previous delivery is its way back" {
  left_by_a_dead_commit
  echo "atticd.service failed" >"$t/units"
  run --separate-stderr "$t/run" "$cli" converge <"$t/stdin"
  [ "$status" -eq 1 ]
  [[ $stderr == *"is unhealthy: its previous delivery is kept"* ]]
  [ -d "$t/attic/.previous-ndh-incus-attic-20261022T184302Z" ]
  [ -d "$t/zfs/tank/x@ndh-incus-attic-20261022T145633Z" ]
}

@test "mutant: an up-to-date container with leftovers left as it is never finishes the commit" {
  left_by_a_dead_commit
  grep -q '      elif \[ -n "\$rest" \]; then' "$cli"
  sed 's/      elif \[ -n "\$rest" \]; then/      elif false; then/' "$cli" >"$t/mutant"
  run --separate-stderr "$t/run" "$t/mutant" converge <"$t/stdin"
  run no_leftovers
  [ "$status" -ne 0 ]
}

@test "the health wait waits out a guest without systemctl yet, quietly" {
  delivered_before
  echo 3 >"$t/no-systemctl"
  run --separate-stderr "$t/run" "$cli" converge <"$t/stdin"
  [ "$status" -eq 0 ]
  [[ $output == *healthy* ]]
  [[ $stderr != *"Command not found"* ]]
  [ "$(cat "$t/no-systemctl")" = 0 ]
}

@test "mutant: without the wait, the probes run into the guest's missing systemctl" {
  delivered_before
  echo 3 >"$t/no-systemctl"
  # The probes see no systemctl either while it lasts.
  grep -q 'GUEST_SYSTEMCTL" --version >/dev/null 2>&1; do' "$cli"
  sed 's/until incus exec --project "\$PROJECT" "\$1" -- "\$GUEST_SYSTEMCTL" --version >\/dev\/null 2>&1; do/until true; do/' "$cli" >"$t/mutant"
  run --separate-stderr "$t/run" "$t/mutant" converge <"$t/stdin"
  [[ $stderr == *"Command not found"* ]]
  [[ $output != *healthy* ]]
}

@test "a snapshot mounted again between the umount and the destroy is retried, and goes" {
  left_by_a_dead_commit
  echo "/nix/.rw-store/.zfs/snapshot/ndh-incus-attic-20261022T145633Z" >"$t/mounts"
  touch "$t/remount-once"
  run --separate-stderr "$t/run" "$cli" converge <"$t/stdin"
  [ "$status" -eq 0 ]
  [[ $stderr == *"dataset is busy"* ]]
  no_leftovers
}

@test "a new declared system over today's leftovers: the old commit is finished first, then one delivery" {
  left_by_a_dead_commit
  # A new toplevel declared (another class of attic, say): a fresh delivery.
  touch "$t/x-attic-2"
  sed '/^INSTANCES=/a INSTANCES=$(yq -p json -o json -I0 '"'"'.attic.toplevel += "-2"'"'"' <<<"$INSTANCES")' "$cli" >"$t/cli-2"
  mkdir -p "$t/rw/.zfs/snapshot/ndh-incus-attic-20261018T000000Z/upper"
  run --separate-stderr "$t/run" "$t/cli-2" converge <"$t/stdin"
  [ "$status" -eq 0 ]
  [[ $output == *"previous delivery committed"* && $output == *"x-attic-2, healthy"* ]]
  [ "$(readlink "$t/attic/root/nix/var/nix/profiles/system")" = "$t/x-attic-2" ]
  # Only the new delivery's pair is left, and nothing aside.
  [ -z "$(ls -d "$t/zfs/tank/x@"* 2>/dev/null | grep -v '@ndh-incus-attic-20261018T000000Z$')" ]
  [ -z "$(ls -d "$t/zfs/tank/nerd/attic@"* 2>/dev/null)" ]
  [ -z "$(ls -d "$t/attic"/.previous-* 2>/dev/null)" ]
}

@test "mutant: without finishing the old commit first, a failed new delivery rolls the old aside back too" {
  left_by_a_dead_commit
  touch "$t/x-attic-2"
  sed '/^INSTANCES=/a INSTANCES=$(yq -p json -o json -I0 '"'"'.attic.toplevel += "-2"'"'"' <<<"$INSTANCES")' "$cli" >"$t/cli-2"
  mkdir -p "$t/rw/.zfs/snapshot/ndh-incus-attic-20261018T000000Z/upper"
  grep -q '    if \[ -n "\$rest" \]; then' "$t/cli-2"
  sed 's/^    if \[ -n "\$rest" \]; then/    if false; then/' "$t/cli-2" >"$t/mutant"
  echo "$t/attic/root/nix/var/nix/profiles/per-user/root/runtime" >"$t/nix-env-fails"
  run --separate-stderr "$t/run" "$t/mutant" converge <"$t/stdin"
  # The old delivery's aside is rolled back as well: its state snapshot is restored.
  grep -q '^zfs rollback -r tank/nerd/attic@ndh-incus-attic-20261022T184302Z$' "$t/calls"
}

@test "_commit refuses a snapshot to keep that is not a delivery snapshot of this instance, and destroys nothing" {
  left_by_a_dead_commit
  for snapshot in '.*' '' 'ndh-incus-attic-.*' 'ndh-incus-other-20261022T184302Z' '../x' 'a@b' \
    'ndh-incus-attic-20261022T184302Z@x' 'ndh-incus-attic-2026102T184302Z'; do
    : >"$t/calls"
    run --separate-stderr "$t/run" "$cli" _commit attic "$snapshot" <"$t/stdin"
    [ "$status" -ne 0 ]
    run grep -E '^(zfs destroy|umount)' "$t/calls"
    [ "$status" -eq 1 ]
  done
  [ -d "$t/zfs/tank/x@ndh-incus-attic-20261022T184302Z" ]
  [ -d "$t/zfs/tank/x@ndh-incus-attic-20261022T145633Z" ]
  [ -d "$t/attic/.previous-ndh-incus-attic-20261022T184302Z" ]
}

@test "mutant: a _commit without its check, given .*, destroys the snapshot the container runs on" {
  left_by_a_dead_commit
  awk '/^commit_steps\(\) \{/{r=1} r && /^  delivery_snapshot "\$1" "\$2"$/{r=0; next} {print}' "$cli" >"$t/mutant"
  [ "$(grep -c '^  delivery_snapshot "\$1" "\$2"$' "$t/mutant")" = 1 ]
  # Still matched as a fixed string: `.*` keeps nothing but itself, so every delivery snapshot goes, the current one too.
  run --separate-stderr "$t/run" "$t/mutant" _commit attic '.*' <"$t/stdin"
  [ ! -d "$t/zfs/tank/x@ndh-incus-attic-20261022T184302Z" ]
}

@test "mutant: 0e46f6a7's _commit (no check, the snapshot to keep as a pattern) keeps the old one and destroys the current" {
  left_by_a_dead_commit
  # The check gone, and `grep -v "@$2$"` back in place of the fixed-string match. `.*` there excludes every line, so
  # it keeps all (measured); the danger is a pattern that matches ANOTHER snapshot: it keeps that one instead.
  grep -q 'grep -vxF -e "\$rw@\$2" -e "\$db@\$2"' "$cli"
  sed 's/grep -vxF -e "\$rw@\$2" -e "\$db@\$2"/grep -v "@$2$"/' "$cli" |
    awk '/^commit_steps\(\) \{/{r=1} r && /^  delivery_snapshot "\$1" "\$2"$/{r=0; next} {print}' >"$t/mutant"
  [ "$(grep -c 'grep -v "@\$2\$"' "$t/mutant")" = 1 ]
  run --separate-stderr "$t/run" "$t/mutant" _commit attic 'ndh-incus-attic-2026102.T14....Z' <"$t/stdin"
  [ -d "$t/zfs/tank/x@ndh-incus-attic-20261022T145633Z" ]
  [ ! -d "$t/zfs/tank/x@ndh-incus-attic-20261022T184302Z" ]
}

# A snapshot another tool takes of the state during the failed window (an auto-snapshot, a backup): newer than
# the delivery's, it holds the rejected system's data. `zfs rollback -r` destroys it; without -r the rollback refuses.
foreign_snapshot_on_start() {
  printf '#!%s\n[ -e %q ] || { echo schema-2 >%q; touch %q; %q snapshot tank/nerd/attic@autosnap; }\n' \
    "$BASH" "$t/migrated" "$t/zfs/tank/nerd/attic/db" "$t/migrated" "$t/bin/zfs" >"$t/on-start"
  chmod +x "$t/on-start"
}

@test "the rollback destroys a snapshot taken of the state during the failed window, and restores the data" {
  delivered_before
  echo "atticd.service failed" >"$t/units"
  foreign_snapshot_on_start
  run --separate-stderr "$t/run" "$cli" converge <"$t/stdin"
  [ "$status" -eq 1 ]
  # It was taken, after the delivery's snapshot.
  grep -qxF tank/nerd/attic@autosnap "$t/zfs/order"
  [ ! -d "$t/zfs/tank/nerd/attic@autosnap" ]
  [ "$(cat "$t/zfs/tank/nerd/attic/db")" = schema-1 ]
}

@test "mutant: a state rollback without -r leaves the rejected system's data in place" {
  delivered_before
  echo "atticd.service failed" >"$t/units"
  foreign_snapshot_on_start
  sed 's/zfs rollback -r "\$fs@\$2"/zfs rollback "$fs@$2"/' "$cli" >"$t/mutant"
  run grep -c 'zfs rollback "\$fs@\$2"' "$t/mutant"
  [ "$output" = 1 ]
  run --separate-stderr "$t/run" "$t/mutant" converge <"$t/stdin"
  [[ $stderr == *"more recent snapshots exist"* ]]
  [ "$(cat "$t/zfs/tank/nerd/attic/db")" = schema-2 ]
}

# The cluster's two guests: this one is bioskop's, and its cache container is now declared attic-bioskop, renamed from
# attic. Derived from the suite's CLI by its declaration alone.
per_metalspace_cli() {
  touch "$t/clustered"
  sed '/^INSTANCES=/a INSTANCES=$(yq -p json -o json -I0 '"'"'with_entries(.key = "attic-bioskop" | .value.name = "attic-bioskop" | .value.target = "bioskop" | .value.renamedFrom = "attic" | .value.dir |= sub("/attic$"; "/attic-bioskop") | .value.dataset |= sub("/attic$"; "/attic-bioskop"))'"'"' <<<"$INSTANCES")' "$cli" >"$t/cli-ms"
  [ "$(grep -c 'attic-bioskop' "$t/cli-ms")" = 1 ]
}

# bioskop's attic as it ran on 2026-10-24: on member bioskop, healthy, delivered on 184302Z, its container dataset and
# that delivery's snapshots (store upper, DB, state) all named attic.
running_attic_before_rename() {
  per_metalspace_cli
  echo bioskop >"$t/inst/attic"
  touch "$t/inst/attic.running"
  mkdir -p "$t/attic/root/nix/var/nix/profiles/per-user/root" "$t/attic/root/nix/.lower/nix/store" \
    "$t/attic/root/nix/.lower/nix/var/nix" "$t/attic/root/nix/.upper" "$t/attic/upper"
  ln -sfn "$t/x-attic" "$t/attic/root/nix/var/nix/profiles/system"
  ln -sfn "$t/x-runtime" "$t/attic/root/nix/var/nix/profiles/per-user/root/runtime"
  echo ndh-incus-attic-20261024T184302Z >"$t/attic/lower.snapshot"
  echo the-cache >"$t/attic/upper/marker"
  # The container dataset, its contents being the dir above: the stub's rename moves the one, the test reads the other.
  mkdir -p "$t/zfs/tank/nerd/ndh-containers/attic"
  echo "$t/attic" >"$t/zfs/tank/nerd/ndh-containers/attic.mountpoint"
  for ds in tank/x tank/db tank/nerd/attic; do mkdir -p "$t/zfs/$ds@ndh-incus-attic-20261024T184302Z"; done
}

# Everything a rename moves, named after attic-bioskop, and nothing left named after attic.
renamed() {
  [ -e "$t/inst/attic-bioskop" ] && [ -e "$t/inst/attic-bioskop.running" ]
  [ ! -e "$t/inst/attic" ]
  [ -d "$t/zfs/tank/nerd/ndh-containers/attic-bioskop" ]
  [ ! -e "$t/zfs/tank/nerd/ndh-containers/attic" ]
  for ds in tank/x tank/db; do
    [ -d "$t/zfs/$ds@ndh-incus-attic-bioskop-20261024T184302Z" ]
    [ ! -e "$t/zfs/$ds@ndh-incus-attic-20261024T184302Z" ]
  done
  # The state snapshot was only a way back: the same converge commits it, under its new name.
  [ -z "$(ls -d "$t/zfs/tank/nerd/attic@"* 2>/dev/null)" ]
}

# As it ran before: attic on bioskop, running, its dataset and snapshots named attic.
as_before() {
  [ -e "$t/inst/attic" ] && [ -e "$t/inst/attic.running" ]
  [ "$(cat "$t/inst/attic")" = bioskop ]
  [ ! -e "$t/inst/attic-bioskop" ]
  [ "$(cat "$t/attic/upper/marker")" = the-cache ]
  [ "$(cat "$t/attic/lower.snapshot")" = ndh-incus-attic-20261024T184302Z ]
  [ ! -e "$t/attic-bioskop" ]
  [ -d "$t/zfs/tank/nerd/ndh-containers/attic" ]
  [ ! -e "$t/zfs/tank/nerd/ndh-containers/attic-bioskop" ]
  for ds in tank/x tank/db tank/nerd/attic; do
    [ -d "$t/zfs/$ds@ndh-incus-attic-20261024T184302Z" ]
    [ ! -e "$t/zfs/$ds@ndh-incus-attic-bioskop-20261024T184302Z" ]
  done
}

@test "converge refuses an instance of its name running on another member, and touches nothing" {
  per_metalspace_cli
  echo nikopol >"$t/inst/attic-bioskop"
  touch "$t/inst/attic-bioskop.running"
  run --separate-stderr "$t/run" "$t/cli-ms" converge <"$t/stdin"
  [ "$status" -eq 1 ]
  [[ $stderr == *"attic-bioskop runs on member nikopol, not on its target bioskop"* ]]
  [ -e "$t/inst/attic-bioskop.running" ]
  run grep -E '^(incus (stop|start|rename|config)|zfs (snapshot|destroy|rename)|systemctl stop)' "$t/calls"
  [ "$status" -eq 1 ]
}

@test "mutant: without the member check, converge stops the other guest's container" {
  per_metalspace_cli
  echo nikopol >"$t/inst/attic-bioskop"
  touch "$t/inst/attic-bioskop.running"
  # A delivered container as the other guest has it, so the member check is the only thing in the way.
  mkdir -p "$t/attic-bioskop/root/nix/var/nix/profiles" "$t/rw/.zfs/snapshot/ndh-incus-attic-bioskop-20261018T000000Z/upper"
  echo ndh-incus-attic-bioskop-20261001T000000Z >"$t/attic-bioskop/lower.snapshot"
  grep -q '    if \[ "\$where" != absent \] && ! placed "\$where" "\$target"; then' "$t/cli-ms"
  sed 's/    if \[ "\$where" != absent \] \&\& ! placed "\$where" "\$target"; then/    if false; then/' "$t/cli-ms" |
    sed 's/  placed "\$where" "\$target" || die "\$1 runs on member/  true || die "$1 runs on member/' >"$t/mutant"
  run --separate-stderr "$t/run" "$t/mutant" converge <"$t/stdin"
  grep -q '^incus stop --project ndh attic-bioskop$' "$t/calls"
}

@test "deliver refuses an instance running on another member than its target" {
  per_metalspace_cli
  echo nikopol >"$t/inst/attic-bioskop"
  run --separate-stderr "$t/run" "$t/cli-ms" deliver attic-bioskop <"$t/stdin"
  [ "$status" -ne 0 ]
  [[ $stderr == *"runs on member nikopol, not on its target bioskop"* ]]
  run grep -E '^(incus stop|zfs snapshot)' "$t/calls"
  [ "$status" -eq 1 ]
}

@test "create refuses a name another member already runs" {
  per_metalspace_cli
  echo nikopol >"$t/inst/attic-bioskop"
  run --separate-stderr "$t/run" "$t/cli-ms" create attic-bioskop <"$t/stdin"
  [ "$status" -ne 0 ]
  [[ $stderr == *"already exists on member nikopol"* ]]
  run grep -E '^incus init' "$t/calls"
  [ "$status" -eq 1 ]
}

@test "converge renames bioskop's running attic to attic-bioskop, data and delivery snapshots with it, healthy" {
  running_attic_before_rename
  run --separate-stderr "$t/run" "$t/cli-ms" converge <"$t/stdin"
  [ "$status" -eq 0 ]
  [[ $output == *"attic renamed attic-bioskop, healthy"* ]]
  renamed
  # The container's own data came along: the dataset is mounted at its dir, and moved with it.
  [ "$(cat "$t/attic-bioskop/upper/marker")" = the-cache ]
  [ ! -e "$t/attic" ]
  [ "$(cat "$t/attic-bioskop/lower.snapshot")" = ndh-incus-attic-bioskop-20261024T184302Z ]
  # raw.lxc and the four store devices point into the new dir.
  # raw.lxc is two lines (init, then the pre-start hook naming the dir), so the call spans two lines of calls.
  grep -A1 '^incus config set --project ndh attic-bioskop raw.lxc=' "$t/calls" | grep -q "pre-start = .* $t/attic-bioskop$"
  for d in nix nix-lower-store nix-lower-db nix-upper; do
    grep -q "^incus config device set --project ndh attic-bioskop $d source=$t/attic-bioskop/" "$t/calls"
  done
  grep -q '^systemctl stop ndh-incus-container-store-attic.service$' "$t/calls"
  grep -q '^systemctl start ndh-incus-container-store-attic-bioskop.service$' "$t/calls"
}

@test "mutant: a rename that leaves the delivery snapshots named after attic pins them past every commit" {
  running_attic_before_rename
  grep -q '    zfs rename "\$snap" "\${snap%@\*}@ndh-incus-\$1-' "$t/cli-ms"
  sed '/^    zfs rename "\$snap" "\${snap%@\*}@ndh-incus-\$1-/d' "$t/cli-ms" >"$t/mutant"
  run --separate-stderr "$t/run" "$t/mutant" converge <"$t/stdin"
  run renamed
  [ "$status" -ne 0 ]
  [ -d "$t/zfs/tank/x@ndh-incus-attic-20261024T184302Z" ]
}

@test "a renamed container unhealthy on the same system is put back exactly, and the failure is loud" {
  running_attic_before_rename
  echo "atticd.service failed" >"$t/units"
  run --separate-stderr "$t/run" "$t/cli-ms" converge <"$t/stdin"
  [ "$status" -eq 1 ]
  [[ $stderr == *"attic-bioskop is unhealthy after its rename: putting attic back"* ]]
  as_before
  grep -q '^systemctl start ndh-incus-container-store-attic.service$' "$t/calls"
}

@test "mutant: without the undo, an unhealthy rename is left half-renamed" {
  running_attic_before_rename
  echo "atticd.service failed" >"$t/units"
  grep -q 'unrename "\$name" "\$old" ||' "$t/cli-ms"
  sed 's/unrename "\$name" "\$old" ||/true ||/' "$t/cli-ms" >"$t/mutant"
  run --separate-stderr "$t/run" "$t/mutant" converge <"$t/stdin"
  run as_before
  [ "$status" -ne 0 ]
}

# Each step of the rename, failing in turn: what was done before it is undone, and attic runs as before.
@test "a rename failing at the dataset is undone, attic as before" {
  running_attic_before_rename
  touch "$t/zfs-rename-fails"
  run --separate-stderr "$t/run" "$t/cli-ms" converge <"$t/stdin"
  [ "$status" -eq 1 ]
  [[ $stderr == *"attic could not be renamed attic-bioskop: putting it back"* ]]
  rm "$t/zfs-rename-fails"
  as_before
}

@test "a rename failing at the mountpoint is undone, attic as before" {
  running_attic_before_rename
  # The rename's own mountpoint set fails; the undo's set (back to attic's dir) goes through.
  echo 1 >"$t/zfs-set-fails"
  run --separate-stderr "$t/run" "$t/cli-ms" converge <"$t/stdin"
  [ "$status" -eq 1 ]
  [[ $stderr == *"could not be renamed"* ]]
  as_before
}

@test "a rename failing at the instance is undone, the snapshots and the dataset named attic again" {
  running_attic_before_rename
  touch "$t/incus-rename-fails"
  run --separate-stderr "$t/run" "$t/cli-ms" converge <"$t/stdin"
  [ "$status" -eq 1 ]
  [[ $stderr == *"could not be renamed"* ]]
  rm "$t/incus-rename-fails"
  as_before
}

@test "another member's attic is no rename of this guest's attic-bioskop: it is created beside it, attic untouched" {
  per_metalspace_cli
  echo nikopol >"$t/inst/attic"
  touch "$t/inst/attic.running"
  mkdir -p "$t/rw/.zfs/snapshot/ndh-incus-attic-bioskop-20261018T000000Z/upper"
  run --separate-stderr "$t/run" "$t/cli-ms" converge <"$t/stdin"
  [ "$status" -eq 0 ]
  [ "$(cat "$t/inst/attic-bioskop")" = bioskop ]
  [ "$(cat "$t/inst/attic")" = nikopol ]
  [ -e "$t/inst/attic.running" ]
  run grep -E '^(incus (stop|rename) --project ndh attic$|incus rename|zfs rename)' "$t/calls"
  [ "$status" -eq 1 ]
}

@test "_rename and _unrename refuse an old name outside an instance name's shape, or the same name, and touch nothing" {
  running_attic_before_rename
  for old in 'a.b' '../attic' 'attic/x' '' 'ATTIC' 'attic;x' 'attic-bioskop'; do
    for verb in _rename _unrename; do
      : >"$t/calls"
      run --separate-stderr "$t/run" "$t/cli-ms" "$verb" attic-bioskop "$old" <"$t/stdin"
      [ "$status" -ne 0 ]
      run grep -E '^(incus (stop|start|rename|config)|zfs (rename|set)|systemctl (stop|start))' "$t/calls"
      [ "$status" -eq 1 ]
    done
  done
  as_before
}

@test "mutant: a rename without the old name's check takes a dotted name into a dataset path" {
  running_attic_before_rename
  # `a.b` names no instance, so a later check refuses it too: the mutant shows the shape check is what refuses FIRST.
  awk '/^rename_steps\(\) \{/{r=1} r && /^  instance_name "\$2"$/{r=0; next} {print}' "$t/cli-ms" >"$t/mutant"
  [ "$(grep -c '^  instance_name "\$2"$' "$t/mutant")" = 1 ]
  run --separate-stderr "$t/run" "$t/mutant" _rename attic-bioskop 'a.b' <"$t/stdin"
  [[ $stderr != *"'a.b' is not an instance name"* ]]
  run --separate-stderr "$t/run" "$t/cli-ms" _rename attic-bioskop 'a.b' <"$t/stdin"
  [[ $stderr == *"'a.b' is not an instance name"* ]]
}

# A declared container no member has: converge creates it, then delivers it.
absent_everywhere() {
  per_metalspace_cli
  mkdir -p "$t/rw/.zfs/snapshot/ndh-incus-attic-bioskop-20261018T000000Z/upper"
}

@test "converge creates a declared container no member has, on its target, and keeps it healthy" {
  absent_everywhere
  run --separate-stderr "$t/run" "$t/cli-ms" converge <"$t/stdin"
  [ "$status" -eq 0 ]
  [[ $output == *"attic-bioskop created on bioskop"* && $output == *"healthy"* ]]
  [ "$(cat "$t/inst/attic-bioskop")" = bioskop ]
  [ -e "$t/inst/attic-bioskop.running" ]
  [ -d "$t/zfs/tank/nerd/ndh-containers/attic-bioskop" ]
  [ ! -e "$t/attic-bioskop/converge.created" ]
  grep -q '^incus init --empty --project ndh --storage default --target bioskop attic-bioskop ' "$t/calls"
}

@test "a container converge created and could not deliver healthy is removed, its state dataset untouched" {
  absent_everywhere
  echo schema-1 >"$t/zfs/tank/nerd/attic/db"
  echo "atticd.service failed" >"$t/units"
  run --separate-stderr "$t/run" "$t/cli-ms" converge <"$t/stdin"
  [ "$status" -eq 1 ]
  [[ $stderr == *"attic-bioskop was unhealthy on its first system and is removed"* ]]
  [ ! -e "$t/inst/attic-bioskop" ]
  [ ! -e "$t/zfs/tank/nerd/ndh-containers/attic-bioskop" ]
  [ ! -e "$t/attic-bioskop" ]
  [ -z "$(ls -d "$t/zfs/tank/x@ndh-incus-attic-bioskop-"* 2>/dev/null)" ]
  # The service's data is the module's, never converge's to remove.
  [ "$(cat "$t/zfs/tank/nerd/attic/db")" = schema-1 ]
}

@test "mutant: a created container left in place when unhealthy" {
  absent_everywhere
  echo "atticd.service failed" >"$t/units"
  grep -q '    elif \[ -e "\$dir/converge.created" \]; then' "$t/cli-ms"
  sed 's/    elif \[ -e "\$dir\/converge.created" \]; then/    elif false; then/' "$t/cli-ms" >"$t/mutant"
  run --separate-stderr "$t/run" "$t/mutant" converge <"$t/stdin"
  [ -e "$t/inst/attic-bioskop" ]
}

@test "a container converge created whose delivery fails is removed" {
  absent_everywhere
  echo "$t/attic-bioskop/root/nix/var/nix/profiles/per-user/root/runtime" >"$t/nix-env-fails"
  run --separate-stderr "$t/run" "$t/cli-ms" converge <"$t/stdin"
  [ "$status" -eq 1 ]
  [[ $stderr == *"attic-bioskop could not be delivered"* && $stderr == *"attic-bioskop removed"* ]]
  [ ! -e "$t/inst/attic-bioskop" ]
  [ ! -e "$t/zfs/tank/nerd/ndh-containers/attic-bioskop" ]
}

@test "mutant: a created container whose delivery fails is rolled back to nothing instead of removed" {
  absent_everywhere
  echo "$t/attic-bioskop/root/nix/var/nix/profiles/per-user/root/runtime" >"$t/nix-env-fails"
  grep -q '      if \[ -e "\$dir/converge.created" \]; then' "$t/cli-ms"
  sed 's/      if \[ -e "\$dir\/converge.created" \]; then/      if false; then/' "$t/cli-ms" >"$t/mutant"
  run --separate-stderr "$t/run" "$t/mutant" converge <"$t/stdin"
  [ -e "$t/inst/attic-bioskop" ]
}

@test "converge never creates a container whose name another member runs" {
  per_metalspace_cli
  echo nikopol >"$t/inst/attic-bioskop"
  run --separate-stderr "$t/run" "$t/cli-ms" converge <"$t/stdin"
  [ "$status" -eq 1 ]
  run grep -E '^(incus init|zfs create)' "$t/calls"
  [ "$status" -eq 1 ]
}

@test "_uncreate refuses a container converge did not create, and removes nothing" {
  running_attic_before_rename
  echo bioskop >"$t/inst/attic-bioskop"
  mkdir -p "$t/attic-bioskop" "$t/zfs/tank/nerd/ndh-containers/attic-bioskop"
  run --separate-stderr "$t/run" "$t/cli-ms" _uncreate attic-bioskop <"$t/stdin"
  [ "$status" -ne 0 ]
  [[ $stderr == *"was not created by converge: nothing removed"* ]]
  [ -e "$t/inst/attic-bioskop" ]
  [ -d "$t/zfs/tank/nerd/ndh-containers/attic-bioskop" ]
}

