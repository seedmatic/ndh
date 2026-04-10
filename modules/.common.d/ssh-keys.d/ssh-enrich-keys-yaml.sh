#!/usr/bin/env -S bash -euo pipefail
# @codebase
# Enrich SSH key material for a selected profile and output normalized YAML.
# Used by system-side enrichment flows (NixOS + Darwin).

shopt -s extglob

declare -g keyFields="type|usage|comment|public|private|authorities|principals|domain|authorized_keys_options|annotations"

: "Function to handle tracing"
log::trace() {
	if [[ -z "${TRACE:=}" ]]; then
		return
	else
		echo "TRACE: $*" >&2
	fi
}

: "Function to convert a string to snake_case"
var::snakeCase() {
	local var="${1//./_}" &&
		var="${var//-/_}" &&
		if [[ $# -gt 1 ]]; then
			shift
			var+="_$(var::snakeCase "$@")"
		fi
	echo "${var,,}"
}

: "Function to get the private key variable name for an authority"
var::authorityKey() {
	var::snakeCase "${profileVarPrefix}" "${@}"
}

: "Function to get hostnames for an authority"
key::authorityHostNames() {
	local authorityName
	authorityName="$1"

	local domain
	domain="$(key::value "authorities" "${authorityName}" "domain")"

	local -A hostNames=()
	hostNames["${hostName}"]=1
	hostNames["${hostName}.lan"]=1
	hostNames["${hostName}.local"]=1
	hostNames["${hostName}.${domain}"]=1

	hostNames[$(hostname -f)]=1
	hostNames[$(hostname -s)]=1
	hostNames[$(hostname -s).${domain}]=1

	if [[ -n "${hostsCatalogCsv:-}" ]]; then
		local catalogHost
		IFS=',' read -r -a catalogHosts <<<"${hostsCatalogCsv}"
		for catalogHost in "${catalogHosts[@]}"; do
			[[ -n "${catalogHost}" ]] || continue
			hostNames["${catalogHost}"]=1
			hostNames["${catalogHost}.lan"]=1
			hostNames["${catalogHost}.local"]=1
			hostNames["${catalogHost}.${domain}"]=1
		done
	fi

	printf '%s\n' "${!hostNames[@]}"
}

key::principals() {
	local principalsVar principals
	principalsVar="$(var::snakeCase "${keyVar}" "principals")"
	principals=()
	for var in "${profileVars[@]}"; do
		if [[ $var != "${principalsVar}"* ]]; then
			continue
		fi
		principals+=("${!var}")
	done
	printf "%s\n" "${principals[@]}"
}

key::usage() {
	local usages=()
	local index=0
	while true; do
		local usageVar
		usageVar="$(var::snakeCase "$keyVar" "usage" "$index")"
		local usage="${!usageVar:-}"
		if [ -z "$usage" ]; then
			break
		fi
		usages+=("$usage")
		index=$((index + 1))
	done
	printf "%s\n" "${usages[@]}"
}

key::generateKeyPair() {
	local keyName
	keyName="$1"

	local type
	type="$(key::value "type")"
	type="${type:-ssh-ed25519}"
	type="${type/^ssh-//}"

	local comment
	comment="$(key::value "comment")"
	comment="${comment:-${keyName}}"

	if ! ssh-keygen -q -t "$type" -N "" -f "${tmpdir}/${keyName}" -C "$comment"; then
		log::trace "Failed to generate key pair for $keyName"
		return 1
	fi

	local keyPublic keyPrivate
	keyPublic="$(cut -d' ' -f2,2 <"${tmpdir}/${keyName}.pub")"
	keyPrivate="$(<"${tmpdir}/${keyName}")"

	key::update "$keyPublic" "$keyPrivate"
}

authority::usage() {
	local authoritVar="$1"
	local usages=()
	local index=0
	while true; do
		local usageVar
		usageVar="$(var::snakeCase "$authoritVar" "usage" "$index")"
		local usage="${!usageVar:-}"
		if [ -z "$usage" ]; then
			break
		fi
		usages+=("$usage")
		index=$((index + 1))
	done
	printf "%s\n" "${usages[@]}"
}

key::signWithAuthorities() {
	local signedAuthorities=()

	for profileVar in "${profileVars[@]}"; do
		if ! [[ "$profileVar" =~ ^${keyVar}_authorities_ ]]; then
			continue
		fi

		local authorityName
		authorityName=${profileVar##*_authorities_}
		authorityName=${authorityName%%_@(${keyFields})*}

		if [[ "${signedAuthorities[*]}" =~ ${authorityName} ]]; then
			continue
		fi

		local authorityPrivateKeyVar="${keyVar}_authorities_${authorityName}_private"
		local authorityPublicKeyVar="${keyVar}_authorities_${authorityName}_public"
		local authorityPrivateKey="${!authorityPrivateKeyVar}"
		local authorityPublicKey="${!authorityPublicKeyVar}"

		if [[ -z "${authorityPrivateKey}" ]]; then
			log::trace "Missing private key for authority: ${authorityName}"
			continue
		fi

		authority::signKey "${authorityName}" "${authorityPrivateKey}" "${authorityPublicKey}"
		signedAuthorities+=("$authorityName")
	done
}

authority::signKey() {
	local authorityName authorityVar
	authorityName="$1"
	authorityVar=$(var::snakeCase "${keyVar}" "authorities" "${authorityName}")

	local -a tmpfiles
	trap 'trap - RETURN; rm -f "${tmpfiles[@]}"' RETURN

	local cakeyPrivateVar cakeyPrivateTmpFile
	cakeyPrivateVar="$(var::snakeCase "$keyVar" "authorities" "$authorityName" "private")"
	if [ -z "${!cakeyPrivateVar:-}" ]; then
		return
	fi
	cakeyPrivateTmpFile="${tmpdir}/${authorityName}"
	tmpfiles+=("$cakeyPrivateTmpFile")
	cat <<<"${!cakeyPrivateVar}" >"$cakeyPrivateTmpFile" && chmod 400 "$cakeyPrivateTmpFile"

	local keyPublicLine keyPublicTmpFile keyNameLocal
	keyNameLocal="$(key::name "${keyVar}")"
	local keyPublicRaw keyPublicBlob
	keyPublicRaw="$(key::value "public")"
	keyPublicBlob="$(key::publicBlob "$keyPublicRaw")"
	keyPublicLine="$(key::value "type") ${keyPublicBlob} $(key::value "comment")"
	keyPublicTmpFile="${tmpdir}/${keyNameLocal}.pub"
	tmpfiles+=("$keyPublicTmpFile")
	cat <<<"${keyPublicLine}" >"$keyPublicTmpFile"

	local -a authorityUsage
	readarray -t authorityUsage < <(authority::usage "$authorityVar")
	for usage in "${authorityUsage[@]}"; do
		case "$usage" in
		"ssh-user")
			local principals
			readarray -t principals < <(key::principals)
			local certIdentity
			certIdentity="$(key::certificateIdentity "${keyNameLocal}" "ssh-user")"
			if ! ssh-keygen -q -s "$cakeyPrivateTmpFile" -I "${certIdentity}" -n "$(IFS=','; echo "${principals[*]}")" "$keyPublicTmpFile"; then
				log::trace "Failed to sign user key with authority $authorityName"
				return 1
			fi
			;;
		"ssh-host")
			local authorityHostNames
			readarray -t authorityHostNames < <(key::authorityHostNames "$authorityName")
			local certIdentity
			certIdentity="$(key::certificateIdentity "${keyNameLocal}" "ssh-host")"
			if ! ssh-keygen -q -s "$cakeyPrivateTmpFile" -I "${certIdentity}" -h -n "$(IFS=','; echo "${authorityHostNames[*]}")" "$keyPublicTmpFile"; then
				log::trace "Failed to sign host key with authority $authorityName"
				return 1
			fi
			;;
		"ssh-authority" | "github-signing")
			continue
			;;
		*)
			log::trace "Unknown key usage: $usage"
			return 1
			;;
		esac
		keyCertTmpFile="${keyPublicTmpFile%.pub}-cert.pub"
		ssh-keygen -L -f "$keyCertTmpFile" || log::trace "Could not inspect certificate $keyCertTmpFile"
		keyCertLine="$(cat "${keyCertTmpFile}")"
		declare -g "$(var::snakeCase "${keyVar}" authorities "$authorityName" "$usage")=${keyCertLine}"
	done
}

key::name() {
	local keyVar
	keyVar="$1"
	keyName=${keyVar#"${profileVarPrefix}_"}
	keyName=${keyName%%_@(${keyFields})*}
	echo "$keyName"
}

key::value() {
	local var
	var=$(var::snakeCase "${keyVar}" "${@}")
	echo "${!var:-}"
}

key::publicBlob() {
	local publicRaw="${1:-}"
	[[ -n "$publicRaw" ]] || return 1

	local first second
	read -r first second _ <<<"$publicRaw"
	if [[ "$first" == ssh-* && -n "$second" ]]; then
		echo "$second"
	else
		echo "$first"
	fi
}

key::values() {
	local arrayVar index values
	arrayVar=$(var::snakeCase "${keyVar}" "${@}")
	index=0
	values=()
	while true; do
		local valueVar
		valueVar="$(var::snakeCase "${arrayVar}" "${index}")"
		local value="${!valueVar:-}"
		if [ -z "$value" ]; then
			break
		fi
		values+=("$value")
		index=$((index + 1))
	done
	printf "%s\n" "${values[@]}"
}

key::update() {
	local keyPublic keyPrivate
	keyPublic="${1}"
	keyPrivate="${2}"
	declare -g "$(var::snakeCase "${keyVar}" public)=${keyPublic}"
	declare -g "$(var::snakeCase "${keyVar}" private)=${keyPrivate}"
}

key::certificateIdentity() {
	local keyName="$1"
	local certUsage="$2"
	key::annotationsJson "$keyName" "$certUsage"
}

key::defaultPublicScope() {
	local usage
	readarray -t usage < <(key::usage)
	if [[ " ${usage[*]} " == *" ssh-authority "* ]]; then
		echo "system"
	else
		echo "user"
	fi
}

key::annotationsJson() {
	local KEYNAME="$1"; shift
	local USAGE_LINES
	USAGE_LINES="$(printf '%s\n' "$@")"
	env KEYNAME="$KEYNAME" USAGE_LINES="$USAGE_LINES" yq \
	  --null-input --indent=0 --output-format=json eval \
	  --from-file=<( cat <<'EoYaml'
       {
         "marker": "ndh-ssh-key-meta-v1",
         "owner": "home-manager.ssh-add-keys",
         "key": strenv(KEYNAME),
         "usage": ((strenv(USAGE_LINES) | split("\n")) | map(select(length > 0)))
       }
EoYaml
       )
}

key::annotatedComment() {
	local keyName="$1"
	local baseComment="$2"
	if [[ -n "$baseComment" ]]; then
		echo "${baseComment}"
	else
		echo "${keyName}"
	fi
}

key::process() {
	local keyName="$1"
	declare -g keyVar
	keyVar="$(var::snakeCase "${profileVarPrefix}" "${keyName}")"

	declare keyPublic keyPrivate
	keyPublic=$(key::value "public")
	keyPrivate=$(key::value "private")

	local hasAuthorities=0
	for profileVar in "${profileVars[@]}"; do
		if [[ "$profileVar" =~ ^${keyVar}_authorities_ ]]; then
			hasAuthorities=1
			break
		fi
	done

	if ((hasAuthorities)) && { [ -z "$keyPublic" ] || [ -z "$keyPrivate" ]; }; then
		key::generateKeyPair "$keyName" "$tmpdir"
	fi

	key::signWithAuthorities
}

keys::toYAML() {
	cat <<EOF | yq --prettyPrint eval '.'
keys:
$(
		local -a signingKeys otherKeys
		declare -g keyVar
		local keyName
		for keyName in "${processedKeys[@]}"; do
			keyVar="$(var::snakeCase "${profileVarPrefix}" "${keyName}")"
			readarray -t keyUsage < <(key::usage)
			local accumulator="otherKeys"
			if [[ "${keyUsage[*]}" =~ user-signing ]]; then
				accumulator="signingKeys"
			fi
			if [[ "$accumulator" == "signingKeys" ]]; then
				signingKeys+=("$keyName")
			else
				otherKeys+=("$keyName")
			fi
		done
		local -a orderedKeys=("${otherKeys[@]}" "${signingKeys[@]}")
		for keyName in "${orderedKeys[@]}"; do
			keyVar="$(var::snakeCase "${profileVarPrefix}" "${keyName}")"
			local authorityHostNames keyUsage keyType keyComment keyPublic keyPrivate authorityUsage annotatedComment keyPublicRaw
			readarray -t keyUsage < <(key::usage)
			keyType=$(key::value type)
			keyComment=$(key::value comment)
			keyPublicRaw="$(key::value public)"
			keyPublic="$(key::publicBlob "$keyPublicRaw")"
			keyPrivate=$(key::value private)
			annotatedComment="$(key::annotatedComment "$keyName" "$keyComment" "${keyUsage[@]}")"
			readarray -t keyPrincipals < <(key::principals)
			cat <<EOK
  $keyName:
    usage: $(IFS=','; echo "[ ${keyUsage[*]} ]")
    private: |-
$(echo "$keyPrivate" | sed 's/^/      /')
    public: $keyType $keyPublic $annotatedComment
$(
				if ((${#keyPrincipals[@]} > 0)); then
					printf '    principals: [ '
					(IFS=','; echo "${keyPrincipals[*]}") | sed 's/,/, /g' | sed 's/$/ ]/'
				fi
			)
$(
				local -a processedAuthorities
				processAuthorities=()
				for profileVar in "${profileVars[@]}"; do
					if ! [[ "$profileVar" =~ ^${keyVar}_authorities_ ]]; then
						continue
					fi
					local authorityName
					authorityName=${profileVar##*_authorities_}
					authorityName=${authorityName%%_@(${keyFields})*}
					if [[ "${processedAuthorities[*]}" =~ ${authorityName} ]]; then
						continue
					fi
					processedAuthorities+=("$authorityName")
					if ((${#processedAuthorities[@]} == 1)); then
						echo "    certificates:"
					fi
					local authorityVar
					authorityVar="$(var::snakeCase "$keyVar" "authorities" "$authorityName")"
					echo "      $authorityName:"
					local authorityUsage
					readarray -t authorityUsage < <(authority::usage "$authorityVar")
					for authorityUsage in "${authorityUsage[@]}"; do
						local certVar
						certVar="$(var::snakeCase "$authorityVar" "$authorityUsage")"
						echo "        $authorityUsage: |"
						echo "${!certVar}" | sed 's/^/          /'
					done
				done
			)
EOK
		done
	)
EOF
}

source @bashTrampoline@
source @logger@

main() {
	declare -g profileName hostName inputFile outputFile
	profileName="$1"
	shift
	hostName="$1"
	shift
	inputFile="$1"
	shift
	outputFile="$1"
	shift
	declare -g hostsCatalogCsv
	hostsCatalogCsv="${1:-}"
	shift || true
	local targetUser
	targetUser="${1:-${USER:-}}"

	if [[ ! -r "$inputFile" ]]; then
		echo "missing or unreadable input YAML: $inputFile" >&2
		return 1
	fi

	tmpdir=$(mktemp --directory --suffix=keys.d)
	trap 'rm -rf $tmpdir' EXIT

	eval "$(env PROFILE="$profileName" yq -o shell eval 'explode(...) | .profiles[env(PROFILE)] | { "ssh-keys": . }' - <"$inputFile")"

	declare -g profileVarPrefix
	profileVarPrefix=$(var::snakeCase "ssh-keys")

	declare -g profileVars
	declare -p | grep -oE "${profileVarPrefix}_[^=]+" >"${tmpdir}/profileVars"
	readarray -t profileVars <"${tmpdir}/profileVars"

	declare -g sourceKeyNames
	readarray -t sourceKeyNames < <(env PROFILE="$profileName" yq -r 'explode(...) | .profiles[env(PROFILE)] | keys[]' "$inputFile")

	declare -g processedKeys=()
	for keyName in "${sourceKeyNames[@]}"; do
		[[ -n "$keyName" ]] || continue
		processedKeys+=("$keyName")
		key::process "$keyName"
	done

	local outputDir
	outputDir="$(dirname "$outputFile")"
	if [[ "$(id -u)" -eq 0 && -n "$targetUser" ]]; then
		local targetGroup
		targetGroup="$(id -gn "$targetUser" 2>/dev/null || echo "$targetUser")"
		install -o "$targetUser" -g "$targetGroup" -m 0700 -d "$outputDir"
	else
		install -m 0700 -d "$outputDir"
	fi
	local tmpOutput
	tmpOutput="$(mktemp)"
	if ! keys::toYAML >"$tmpOutput"; then
		echo "failed to render SSH keys YAML to temporary file: $tmpOutput" >&2
		rm -f "$tmpOutput"
		return 1
	fi
	if ! rm -f "$outputFile"; then
		echo "failed to remove previous output file: $outputFile" >&2
		rm -f "$tmpOutput"
		return 1
	fi
	if ! install -m 0400 "$tmpOutput" "$outputFile"; then
		echo "failed to install generated SSH keys YAML to output path: $outputFile" >&2
		rm -f "$tmpOutput"
		return 1
	fi
	rm -f "$tmpOutput"

	if ! chmod 0400 "$outputFile"; then
		echo "failed to enforce read-only mode on output file: $outputFile" >&2
		return 1
	fi
	if [[ "$(id -u)" -eq 0 && -n "$targetUser" ]]; then
		chown "$targetUser" "$outputFile" 2>/dev/null || true
	fi
}

ndh::logger:command:run "@loggerTag@" main "$@"
