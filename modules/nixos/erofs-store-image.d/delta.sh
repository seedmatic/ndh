#!/usr/bin/env bash
# Emits the store paths a layer must carry: the paths of one closure that the
# layers below it do not already hold.
#
# Why a set difference and not a structural rule: the two closures are NOT
# nested.  A bringup system and a runtime system are two different NixOS
# configurations, so everything generated from the configuration (systemd units,
# hwdb, firmware) re-derives in each.  Measured between the bringup and nikopol's
# runtime: 553 paths shared, 1109 only in the runtime, and 106 only in the
# bringup — which is also why the base layer can never be dropped.
#
# The result is deliberately NOT dependency-closed (measured: 142 outbound
# references over 60 sampled delta paths).  Only the whole stack is closed, which
# is why the installer registers the UNION in the target Nix database.
#
# shellcheck source=/dev/null
source "@nixBashTrampoline@"

main() {
  set -euo pipefail
  set -x

  local below_store_paths="$1"
  local layer_store_paths="$2"
  local output="$3"

  # `comm` requires both inputs sorted in ITS collation order, and reports a
  # mismatch only as a warning while still emitting wrong output.  Pinning
  # LC_ALL=C makes the sort and the comparison agree by construction instead of
  # by whatever locale the builder happens to carry.
  export LC_ALL=C

  comm -13 \
    <(sort -u "$below_store_paths") \
    <(sort -u "$layer_store_paths") \
    > "$output"

  if [[ ! -s "$output" ]]; then
    echo "[erofs-store-delta][ERROR] layer would be empty: every path of ${layer_store_paths} is already carried below" >&2
    exit 1
  fi
}

ndh::logger:command:run "@loggerTag@" main "$@"
