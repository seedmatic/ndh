#!/usr/bin/env -S bash -xeuo pipefail

auto_master_target=/etc/static/auto_master

cat > "$auto_master_target" <<'EOF'
@autoMasterText@
EOF
