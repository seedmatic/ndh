#!/usr/bin/env -S bash -euo pipefail
source @nixBashTrampoline@

main() {
	echo "[openssh] start $(date)"

	: "Install group-based AuthorizedKeysCommand script"
	install -d -m 755 /etc/ssh
	install -m 555 @groupKeysScriptStore@ /etc/ssh/@groupKeysCommand@
	install -m 555 @principalsScriptStore@ /etc/ssh/@principalsCommand@

	echo "[openssh] end $(date)"
}

ndh::logger:command:run darwin.activationScripts.etc.openssh main "$@"
