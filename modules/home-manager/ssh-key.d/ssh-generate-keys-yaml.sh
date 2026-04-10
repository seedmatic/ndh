#!/usr/bin/env -S bash -euo pipefail
# @codebase
# Original name: ssh-add-keys.sh (renamed to clarify purpose: generates consolidated keys.yaml)
# This script assembles & (re)generates SSH key material for the selected profile, signing it
# with configured authorities and outputting a normalized YAML document consumed by Home Manager.

# (Content copied verbatim from previous ssh-add-keys.sh)

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
	hostNames["${hostName}.lan"]=1 # bbox gateway domain name
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

# Function to get the allowed principals for a key
key::principals() {
	# Loop through profileVars and filter based on the prefix
	local principalsVar principals
	principalsVar="$(var::snakeCase "${keyVar}" "principals")"
	principals=()
	for var in "${profileVars[@]}"; do
		if [[ $var != "${principalsVar}"* ]]; then
			continue
		fi
		# Get the value of the variable using indirect expansion
		principals+=("${!var}")
	done
	printf "%s\n" "${principals[@]}"
}

: "Function to get the key usages"
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

: "Function to generate a new SSH key pair"
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

	: "Generate the key pair in a temporary directory"
	if ! ssh-keygen -q -t "$type" -N "" -f "${tmpdir}/${keyName}" -C "$comment"; then
		log::trace "Failed to generate key pair for $keyName"
		return 1
	fi

	: "Load the generated key pair into global variables"
	local keyPublic keyPrivate
	keyPublic="$(cut -d' ' -f2,2 <"${tmpdir}/${keyName}.pub")"
	keyPrivate="$(<"${tmpdir}/${keyName}")"

	key::update "$keyPublic" "$keyPrivate"
}

: "Function to get the authority usages"
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

# Function to sign a key with all authorities (deprecated colon style retained intentionally)
# Function to sign a key with all authorities
key::signWithAuthorities() {
	local signedAuthorities=()

	for profileVar in "${profileVars[@]}"; do
		if ! [[ "$profileVar" =~ ^${keyVar}_authorities_ ]]; then
			continue
		fi

		# Extract the authority name from the variable
		local authorityName
		authorityName=${profileVar##*_authorities_}
		# shellcheck disable=SC2295
		authorityName=${authorityName%%_@(${keyFields})*}

		# Check if the authority has already been signed
		if [[ "${signedAuthorities[*]}" =~ ${authorityName} ]]; then
			continue
		fi

		# Construct the variable names for the authority's keys
		local authorityPrivateKeyVar="${keyVar}_authorities_${authorityName}_private"
		local authorityPublicKeyVar="${keyVar}_authorities_${authorityName}_public"

		# Retrieve the authority's keys
		local authorityPrivateKey="${!authorityPrivateKeyVar}"
		local authorityPublicKey="${!authorityPublicKeyVar}"

		# Ensure the authority's private key is available
		if [[ -z "${authorityPrivateKey}" ]]; then
			log::trace "Missing private key for authority: ${authorityName}"
			continue
		fi

		# Sign the key with the authority
		authority::signKey "${authorityName}" "${authorityPrivateKey}" "${authorityPublicKey}"

		# Add the authority to the list of signed authorities
		signedAuthorities+=("$authorityName")
	done
}

: "Function to sign a key with an authority"
authority::signKey() {
	local authorityName authorityVar
	authorityName="$1"
	authorityVar=$(var::snakeCase "${keyVar}" "authorities" "${authorityName}")

	local -a tmpfiles
	trap 'trap - RETURN; rm -f "${tmpfiles[@]}"' RETURN

	: "Construct the variable names for the authority's key"
	local cakeyPrivateVar cakeyPrivateTmpFile
	cakeyPrivateVar="$(var::snakeCase "$keyVar" "authorities" "$authorityName" "private")"
	if [ -z "${!cakeyPrivateVar:-}" ]; then
		return
	fi
	cakeyPrivateTmpFile="${tmpdir}/${authorityName}"
	tmpfiles+=("$cakeyPrivateTmpFile")
	cat <<<"${!cakeyPrivateVar}" >"$cakeyPrivateTmpFile" &&
		chmod 400 "$cakeyPrivateTmpFile"

	: "Construct the variable names for the public's key (derive key name locally to avoid outer-scope reliance)"
	local keyPublicLine keyPublicTmpFile keyNameLocal
	keyNameLocal="$(key::name "${keyVar}")"
	local keyPublicRaw keyPublicBlob
	keyPublicRaw="$(key::value "public")"
	keyPublicBlob="$(key::publicBlob "$keyPublicRaw")"
	keyPublicLine="$(key::value "type") ${keyPublicBlob} $(key::value "comment")"
	keyPublicTmpFile="${tmpdir}/${keyNameLocal}.pub"
	tmpfiles+=("$keyPublicTmpFile")
	cat <<<"${keyPublicLine}" >"$keyPublicTmpFile"

	: "Determine the usage of the key (user or host)"
	local -a authorityUsage
	readarray -t authorityUsage < <(authority::usage "$authorityVar")
	for usage in "${authorityUsage[@]}"; do
		case "$usage" in
		"ssh-user")
			: "Get the allowed principals for the key"
			local principals
			readarray -t principals < <(key::principals)
			local certIdentity
			certIdentity="$(key::certificateIdentity "${keyNameLocal}" "ssh-user")"
			if ! ssh-keygen -q -s "$cakeyPrivateTmpFile" -I "${certIdentity}" -n "$(
				IFS=','
				echo "${principals[*]}"
			)" "$keyPublicTmpFile"; then
				log::trace "Failed to sign user key with authority $authorityName"
				return 1
			fi
			;;
		"ssh-host")
			: "Get the allowed hostnames for the key"
			local authorityHostNames
			readarray -t authorityHostNames < <(key::authorityHostNames "$authorityName")
			local certIdentity
			certIdentity="$(key::certificateIdentity "${keyNameLocal}" "ssh-host")"
			if ! ssh-keygen -q -s "$cakeyPrivateTmpFile" -I "${certIdentity}" -h -n "$(
				IFS=','
				echo "${authorityHostNames[*]}"
			)" "$keyPublicTmpFile"; then
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

: "Function to get the key name from the variable name"
key::name() {
	local keyVar
	keyVar="$1"

	: "Remove the prefix"
	keyName=${keyVar#"${profileVarPrefix}_"}

	: "Remove any suffix starting from the specified words"
	# shellcheck disable=SC2295
	keyName=${keyName%%_@(${keyFields})*}

	echo "$keyName"
}

: "Function to get the value of a key field"
key::value() {
	local var
	var=$(var::snakeCase "${keyVar}" "${@}")
	echo "${!var:-}"
}

: "Normalize public key material to base64 blob (accept both raw blob and full SSH public line)."
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

: "Function to get the array values of a key field"
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

	: "Update the backed YAML document variables"
	declare -g "$(var::snakeCase "${keyVar}" public)=${keyPublic}"
	declare -g "$(var::snakeCase "${keyVar}" private)=${keyPrivate}"
}

key::certificateIdentity() {
	local keyName="$1"
	local certUsage="$2"
	key::annotationsJson "$keyName" "$certUsage"
}

: "Default public scope based on key usage"
key::defaultPublicScope() {
	local usage
	readarray -t usage < <(key::usage)
	if [[ " ${usage[*]} " == *" ssh-authority "* ]]; then
		echo "system"
	else
		echo "user"
	fi
}

: "Build a normalized SSH key comment with key metadata"
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

: "Function to process a key entry"
key::process() {
	local keyName="$1"

	: "required for updating the backed YAML document variables"
	declare -g keyVar
	keyVar="$(var::snakeCase "${profileVarPrefix}" "${keyName}")"

	declare keyPublic keyPrivate

	: "Load the public key if it exists"
	keyPublic=$(key::value "public")

	: "Load the private key if it exists"
	keyPrivate=$(key::value "private")

	local hasAuthorities=0
	for profileVar in "${profileVars[@]}"; do
		if [[ "$profileVar" =~ ^${keyVar}_authorities_ ]]; then
			hasAuthorities=1
			break
		fi
	done

	: "Generate a new key pair when authority signing requires complete key material"
	if ((hasAuthorities)) && { [ -z "$keyPublic" ] || [ -z "$keyPrivate" ]; }; then
		: "Generate new SSH key pair and update global variables"
		key::generateKeyPair "$keyName" "$tmpdir"
	fi

	: "Sign the key with each authority"
	key::signWithAuthorities
}

: "Function to generate the YAML output file"
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

			# shellcheck disable=SC2034
			local authorityHostNames keyUsage keyType keyComment keyPublic keyPrivate authorityUsage annotatedComment keyPublicRaw
			readarray -t keyUsage < <(key::usage)
			# shellcheck disable=SC2034
			keyType=$(key::value type)
			keyComment=$(key::value comment)
			keyPublicRaw="$(key::value public)"
			keyPublic="$(key::publicBlob "$keyPublicRaw")"
			keyPrivate=$(key::value private)
			# shellcheck disable=SC2034
			annotatedComment="$(key::annotatedComment "$keyName" "$keyComment" "${keyUsage[@]}")"
			# Collect principals (for user-signing semantics) so downstream tools (AuthorizedPrincipalsCommand) can align.
			# shellcheck disable=SC2034
			readarray -t keyPrincipals < <(key::principals)
			cat <<EOK
  $keyName:
    usage: $(
				IFS=','
				echo "[ ${keyUsage[*]} ]"
			)
    private: |-
$(echo "$keyPrivate" | sed 's/^/      /')
    public: $keyType $keyPublic $annotatedComment
$(
				if ((${#keyPrincipals[@]} > 0)); then
					printf '    principals: [ '
					(
						IFS=','
						echo "${keyPrincipals[*]}"
					) | sed 's/,/, /g' | sed 's/$/ ]/'
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
					# shellcheck disable=SC2295
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

: "Should log as part of the activation scripts"
# shellcheck disable=SC1091
source @bashTrampoline@
# shellcheck disable=SC1091
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

	: "Create a temporary directory for signing"
	tmpdir=$(mktemp --directory --suffix=keys.d)
	trap 'rm -rf $tmpdir' EXIT

	: "Load the entire YAML file into shell variables"
	eval "$(env PROFILE="$profileName" yq -o shell eval 'explode(...) | .profiles.[env(PROFILE)] | { "ssh-keys": . }' - <"$inputFile")"

	declare -g profileVarPrefix
	profileVarPrefix=$(var::snakeCase "ssh-keys")

	: "Collect profile variables"
	declare -g profileVars
	declare -p | grep -oE "${profileVarPrefix}_[^=]+" >"${tmpdir}/profileVars"
	readarray -t profileVars <"${tmpdir}/profileVars"

	: "Collect original key names from source YAML to preserve dashed names in output"
	declare -g sourceKeyNames
	readarray -t sourceKeyNames < <(env PROFILE="$profileName" yq -r 'explode(...) | .profiles.[env(PROFILE)] | keys[]' "$inputFile")

	: Process each key entry
	declare -g processedKeys=()
	for keyName in "${sourceKeyNames[@]}"; do
		[[ -n "$keyName" ]] || continue
		processedKeys+=("$keyName")
		key::process "$keyName"
	done

	: "Output the updated keys in a YAML file"
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

	: "Keep decrypted runtime keys file read-only to discourage direct edits"
	if ! chmod 0400 "$outputFile"; then
		echo "failed to enforce read-only mode on output file: $outputFile" >&2
		return 1
	fi
	if [[ "$(id -u)" -eq 0 && -n "$targetUser" ]]; then
		chown "$targetUser" "$outputFile" 2>/dev/null || true
	fi
}

ndh::logger:command:run "@loggerTag@" main "$@"
