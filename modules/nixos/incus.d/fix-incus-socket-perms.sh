set -euxo pipefail
find /run/incus -type f -exec chmod g+rw {} +
find /run/incus -type d -exec chmod g+rwx {} +
