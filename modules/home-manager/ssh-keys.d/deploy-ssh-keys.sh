source @activationLogger@

main() {
  set -euo pipefail

  install -d -m 700 ~/.ssh/keys.d
  @rsync@ -avL \
    --chmod=u+w,go-r \
    --chown=$(id -un):$(id -gn) \
    @keysDir@/ ~/.ssh/keys.d/ || true
}

activation_run "@activationTag@" main "$@"
