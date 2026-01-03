source @activationLogger@

main() {
  set -euo pipefail

  run install -d -m 700 ~/.ssh
  if [ -L ~/.ssh/authorized_keys ]; then
    run rm -f ~/.ssh/authorized_keys
  fi
  if [ ! -f ~/.ssh/authorized_keys ]; then
    run install -m 600 /dev/null ~/.ssh/authorized_keys
  else
    run chmod 600 ~/.ssh/authorized_keys
  fi
}

activation_run "@activationTag@" main "$@"
