set -x
set +e
exec 2> >(tee -a /var/log/darwin-activation-trace.log >&2)
echo "=== Activation started at $(date) ==="
