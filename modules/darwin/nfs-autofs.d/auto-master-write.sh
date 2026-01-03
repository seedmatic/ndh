#!/usr/bin/env -S bash -euo pipefail
source @activationLogger@

main() {
	auto_master_target=/etc/static/auto_master

	cat > "$auto_master_target" <<'EOF'
@autoMasterText@
EOF
}

activation_run darwin.activationScripts.etc.auto-master-write main "$@"
