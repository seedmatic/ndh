#!/usr/bin/env bats
# nfsd-off against a stand-in nfsd, passed as its binary: the exports moved aside and kept, the service
# disabled and stopped, an idempotent rerun, and a loud failure when nfsd will not go away.

bats_require_minimum_version 1.5.0

setup() {
  t="$BATS_TEST_TMPDIR"
  mkdir -p "$t/bin" "$t/etc"
  # The stand-in keeps its state in two files, as macOS keeps it in launchd.
  echo enabled >"$t/enabled"
  echo running >"$t/running"
  cat >"$t/bin/nfsd" <<EOF
#!/usr/bin/env bash
case "\$1" in
  disable) [ -e "$t/stuck" ] || echo disabled >"$t/enabled" ;;
  stop) [ -e "$t/stuck" ] || echo stopped >"$t/running" ;;
  status)
    echo "nfsd service is \$(cat "$t/enabled")"
    if [ "\$(cat "$t/running")" = running ]; then echo "nfsd is running (pid 855, 8 threads)"; else echo "nfsd is not running"; fi
    [ "\$(cat "$t/enabled")" = enabled ] ;;
esac
EOF
  chmod +x "$t/bin/nfsd"
  printf '/Users\t-alldirs -maproot=501:30001 -network 192.168.1.0 -mask 255.255.255.0\n' >"$t/etc/exports"
}

off() { bash -euo pipefail "$BATS_TEST_DIRNAME/../nfsd-off.sh" "$t/etc/exports" "$t/bin/nfsd"; }

@test "the exports are moved aside, kept whole and root-only, and nfsd is disabled and stopped" {
  run off
  [ "$status" -eq 0 ]
  [ ! -e "$t/etc/exports" ]
  aside=$(ls "$t"/etc/exports.ndh-disabled-*)
  grep -qF -- "-maproot=501:30001" "$aside"
  [ "$(stat -c %a "$aside")" = 600 ]
  [ "$(cat "$t/enabled")" = disabled ]
  [ "$(cat "$t/running")" = stopped ]
}

@test "a rerun with nothing left to do succeeds and moves nothing" {
  off
  run off
  [ "$status" -eq 0 ]
  [ "$(ls "$t"/etc/exports.ndh-disabled-* | wc -l)" -eq 1 ]
}

@test "an nfsd that stays enabled fails loudly" {
  touch "$t/stuck"
  run off
  [ "$status" -ne 0 ]
  [[ "$output" == *"still ENABLED"* ]]
}
