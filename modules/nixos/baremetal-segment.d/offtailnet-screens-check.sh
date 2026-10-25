# offtailnet-screens-check: the corporate box's screen openings are EARNED, never loaded.
#
# metalspace-guard ships the set @setName@ empty. This adds a `vip . port` to it only when MagicDNS
# answers that tailnet service with the vip the catalog pins, and rebuilds the set from that list
# alone each run, so an element nothing vouches for never survives. On any mismatch or silence it
# leaves the set empty and fails loud: a re-assigned VIP shuts the door instead of moving it.
#
# The oracle is MagicDNS. Whoever owns the tailnet's DNS owns this check, which is accepted: they
# would own the tailnet anyway.
# shellcheck shell=bash
source @nixBashTrampoline@
PATH="@toolPath@:/usr/bin:/bin"

openings="@openings@"
table="inet metalspace-guard"
set_name="@setName@"
resolver="100.100.100.100"

main() {
	local n name vip port fqdn answer failed=0
	local -a earned=()
	n=$(yq -p json -oy -r 'length' "$openings") || {
		echo "offtailnet-screens-check: cannot read the declared openings" >&2
		nft flush set $table "$set_name"
		return 1
	}
	for ((i = 0; i < n; i++)); do
		name=$(yq -p json -oy -r ".[$i].name" "$openings")
		vip=$(yq -p json -oy -r ".[$i].vip" "$openings")
		port=$(yq -p json -oy -r ".[$i].port" "$openings")
		fqdn="$name.@tailnetDomain@"
		: "MagicDNS's answer for $fqdn, against the pinned $vip"
		: "exactly ONE record, equal to the pin: a second record, the pinned one listed last, must not pass"
		answer=$(dig +short +time=3 +tries=2 A "$fqdn" @"$resolver" 2>/dev/null)
		if [ "$answer" = "$vip" ]; then
			earned+=("$vip . $port")
		else
			echo "offtailnet-screens-check: $fqdn answers '$(tr '\n' ' ' <<<"${answer:-nothing}")', not exactly the pinned $vip: its opening stays shut" >&2
			failed=1
		fi
	done
	: "the set holds exactly what was vouched for this run"
	nft flush set $table "$set_name"
	if [ "${#earned[@]}" -gt 0 ]; then
		nft add element $table "$set_name" "{ $(
			IFS=,
			echo "${earned[*]}"
		) }"
	fi
	echo "offtailnet-screens-check: ${#earned[@]} of $n opening(s) earned"
	return "$failed"
}

ndh::logger:command:run "@loggerTag@" main "$@"
