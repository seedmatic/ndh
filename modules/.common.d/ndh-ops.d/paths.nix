# Where ndh-ops keeps the operator's delegation, root's own: one definition, read by ndh-ops and by the tools that
# check it themselves (keys-reconcile's window, F3).
rec {
  dir = "/var/db/ndh-ops";
  delegation = "${dir}/delegation";
  # Arming items: permissions a tool checks itself in the delegation, not programs (no binary, never run by ndh-ops).
  # fleet-switch requires fleet-switch-seat beside fleet-switch for --with-seat (the operator's decision, 2026-10-26).
  armingItems = [ "fleet-switch-seat" ];
}
