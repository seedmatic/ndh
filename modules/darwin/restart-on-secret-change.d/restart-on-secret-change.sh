# restart-on-secret-change — restart the launchd services that read a sops secret once, at start,
# when the activation just installed a different value for it.
#
# sops-nix installs each activation's secrets into a new generation, /run/secrets.d/<n>, and points
# /run/secrets at it; with keepGenerations = 2 the previous one is still there. A secret is CHANGED
# when its file differs from the previous generation's (`cmp -s`, nothing printed) or the previous
# generation lacks it (a first install, a rename, a reboot that emptied the RAM disk): an extra
# restart is harmless, a stale reader is not.
#
# The manifest has one line per service, tab-separated:
#   <system | gui:<user>> <launchd label> <reason> <secret name> [<secret name>...]
# A secret missing from the NEW generation is an error: the service is left alone, the run fails.
#
# Usage: restart-on-secret-change <secrets link, /run/secrets> <manifest>

link="$1"
manifest="$2"

current="$(readlink "$link")"
if [[ -z "$current" || ! -d "$current" ]]; then
	echo "[restart-on-secret-change][ERROR] ${link} does not point at a secrets generation" >&2
	exit 1
fi
generations="$(dirname "$current")"
n="$(basename "$current")"
previous=""
for g in "$generations"/*; do
	b="$(basename "$g")"
	if [[ ! "$b" =~ ^[0-9]+$ ]] || ((b >= n)); then
		continue
	fi
	if [[ -z "$previous" ]] || ((b > $(basename "$previous"))); then
		previous="$g"
	fi
done

changed() { # <secret name>
	[[ -n "$previous" && -f "${previous}/$1" ]] || return 0
	! cmp -s "${current}/$1" "${previous}/$1"
}

status=0
while IFS=$'\t' read -r domain label reason secrets; do
	[[ -n "$label" ]] || continue
	restart=0
	missing=0
	for secret in $secrets; do
		if [[ ! -f "${current}/${secret}" ]]; then
			echo "[restart-on-secret-change][ERROR] ${label}: ${secret} is absent from the new generation; not restarted" >&2
			missing=1
		elif changed "$secret"; then
			restart=1
		fi
	done
	if ((missing)); then
		status=1
		continue
	fi
	((restart)) || continue
	case "$domain" in
		system) target="system/${label}" ;;
		gui:*) target="gui/$(id -u "${domain#gui:}")/${label}" ;;
		*)
			echo "[restart-on-secret-change][ERROR] ${label}: unknown launchd domain ${domain}" >&2
			status=1
			continue
			;;
	esac
	echo "[restart-on-secret-change] ${label}: ${reason}; restarting it"
	if ! launchctl kickstart -k "$target"; then
		echo "[restart-on-secret-change][WARN] ${label}: kickstart failed (not loaded?); it reads the new value at its next start" >&2
	fi
done <"$manifest"
exit "$status"
