# shellcheck disable=SC1091
source @bashTrampoline@
# shellcheck disable=SC1091
source @logger@

main() {
  set -euo pipefail

  install -d -m 700 ~/.ssh
  if [ -L ~/.ssh/authorized_keys ]; then
    rm -f ~/.ssh/authorized_keys
  fi
  if [ ! -f ~/.ssh/authorized_keys ]; then
    install -m 600 /dev/null ~/.ssh/authorized_keys
  else
    chmod 600 ~/.ssh/authorized_keys
  fi
}

ndh::logger:command:run "@activationTag@" main "$@"
