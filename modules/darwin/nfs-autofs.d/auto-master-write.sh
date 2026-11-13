#!/usr/bin/env -S bash -euo pipefail
source @nixBashTrampoline@

main() {
	auto_master_target=/etc/static/auto_master

	cat > "$auto_master_target" <<'EOF'
@autoMasterText@
EOF
}

ndh::logger:command:run darwin.activationScripts.etc.auto-master-write main "$@"
