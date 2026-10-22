# Where ndh-ops keeps the operator's delegation, root's own: one definition, read by ndh-ops and by the tools that
# check it themselves (keys-reconcile's window, F3).
rec {
  dir = "/var/db/ndh-ops";
  delegation = "${dir}/delegation";
}
