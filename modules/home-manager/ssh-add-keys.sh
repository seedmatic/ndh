#!/usr/bin/env -S bash -exuo pipefail

shopt -s extglob

declare -g keyFields="type|usage|comment|public|private|authorities|principals|domain"

: Function to handle tracing
log::trace() {
    if [[ -z "${TRACE:=}" ]]; then
        return
    else
        echo "TRACE: $*" >&2
    fi
}

: Function to convert a string to snake_case
var::snakeCase() {
    local var="${1//./_}" &&
        var="${var//-/_}" &&
        if [[ $# -gt 1 ]]; then
            shift
            var+="_$(var::snakeCase "$@")"
        fi
    echo "${var,,}"
}

: Function to get the private key variable name for an authority
var::authorityKey() {
    var::snakeCase "${profileVarPrefix}" "${@}"
}

: Function to get hostnames for an authority
key::authorityHostNames() {
    local authorityName
    authorityName="$1"

    : Generate hostname variations
    for name in "${osHostname}" "${hostName}" ; do
    cat <<EOT | cut -c 7-
      ${name}
      ${name}.local
      $( [[ -n "${osDomainName}" ]] && echo "${name}.${osDomainName}")
EOT
    done
    echo "${hostName}.$( key::value "authorities" "$authorityName" "domain" )"
}

# Function to get the allowed principals for a key
key::principals() {
    # Loop through profileVars and filter based on the prefix
    local principalsVar principals
    principalsVar="$( var::snakeCase "${keyVar}" "principals" )"
    principals=()
    for var in "${profileVars[@]}"; do
        if [[ $var != "${principalsVar}"* ]]; then
            continue
        fi
        # Get the value of the variable using indirect expansion
        principals+=( "${!var}" )
    done
    printf "%s\n" "${principals[@]}"
}

: Function to get the key usages
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

: Function to generate a new SSH key pair
key::generateKeyPair() {
    local keyName
    keyName="$1"

    local type
    type="$( key::value "type" )"
    type="${type:-ssh-ed25519}"
    type="${type/^ssh-//}"

    local comment
    comment="$( key::value "comment" )"
    comment="${comment:-${keyName}}"

    : Generate the key pair in a temporary directory
    if ! ssh-keygen -q -t "$type" -N "" -f "${tmpdir}/${keyName}" -C "$comment"; then
        log::trace "Failed to generate key pair for $keyName"
        return 1
    fi


    : Load the generated key pair into global variables
    local keyPublic keyPrivate
    keyPublic="$(cut -d' ' -f2,2 <"${tmpdir}/${keyName}.pub")"
    keyPrivate="$(<"${tmpdir}/${keyName}")"

    key::update "$keyPublic" "$keyPrivate"
}

: Function to get the authority usages
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

: Function to sign a key with all authorities
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

: Function to sign a key with an authority
authority::signKey() {
    local authorityName authorityVar
    authorityName="$1"
    authorityVar=$( var::snakeCase "${keyVar}" "authorities" "${authorityName}" )

    local -a tmpfiles
    trap 'trap - RETURN; rm -f "${tmpfiles[@]}"' RETURN

    : Construct the variable names for the authority\'s key
    local cakeyPrivateVar cakeyPrivateTmpFile
    cakeyPrivateVar="$( var::snakeCase "$keyVar" "authorities" "$authorityName" "private" )"
    if [ -z "${!cakeyPrivateVar:-}" ]; then
        return
    fi
    cakeyPrivateTmpFile="${tmpdir}/${authorityName}"
    tmpfiles+=("$cakeyPrivateTmpFile")
    cat <<<"${!cakeyPrivateVar}" >"$cakeyPrivateTmpFile" &&
        chmod 400 "$cakeyPrivateTmpFile"

    : Construct the variable names for the public\'s key
    local keyPublicLine keyPublicTmpFile
    keyPublicLine="$( key::value "type" ) $( key::value "public" ) $( key::value "comment" )"
    keyPublicTmpFile="${tmpdir}/${keyName}.pub"
    tmpfiles+=("$keyPublicTmpFile")
    cat <<<"${keyPublicLine}" >"$keyPublicTmpFile"

    : Determine the usage of the key \(user or host\)
    local -a authorityUsage
    readarray -t authorityUsage < <(authority::usage "$authorityVar")
    for usage in "${authorityUsage[@]}"; do
        case "$usage" in
        "ssh-user")
            : Get the allowed principals for the key
            local principals
            readarray -t principals < <(key::principals)
            if ! ssh-keygen -q -s "$cakeyPrivateTmpFile" -I "${keyName}" -n "$(
                IFS=',';
                echo "${principals[*]}"
            )" "$keyPublicTmpFile"; then
                log::trace "Failed to sign user key with authority $authorityName"
                return 1
            fi
            ;;
        "ssh-host")
            : Get the allowed hostnames for the key
            local authorityHostNames
            readarray -t authorityHostNames < <(key::authorityHostNames "$authorityName")
            if ! ssh-keygen -q -s "$cakeyPrivateTmpFile" -I "${keyName}" -h -n "$(
                IFS=',';
                echo "${authorityHostNames[*]}"
            )" "$keyPublicTmpFile"; then
                log::trace "Failed to sign host key with authority $authorityName"
                return 1
            fi
            ;;
        "ssh-authority"|"github-signing")
            continue;;
        *)
            log::trace "Unknown key usage: $usage"
            return 1
            ;;
        esac
        keyCertTmpFile="${tmpdir}/${keyName}-cert.pub"
        ssh-keygen -L -f "$keyCertTmpFile"
        keyCertLine="$( cat "${keyCertTmpFile}" )"
        declare -g "$( var::snakeCase "${keyVar}" authorities "$authorityName" "$usage" )=${keyCertLine}"
    done
}

: Function to get the key name from the variable name
key::name() {
    local keyVar
    keyVar="$1"

    : Remove the prefix
    keyName=${keyVar#"${profileVarPrefix}_"}

    : Remove any suffix starting from the specified words
    # shellcheck disable=SC2295
    keyName=${keyName%%_@(${keyFields})*}

    echo "$keyName"
}

: Function to get the value of a key field
key::value() {
    local var
    var=$( var::snakeCase "${keyVar}" "${@}" )
    echo "${!var:-}"
}

: Function to get the array values of a key field
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

    : Update the backed YAML document variables
    declare -g "$( var::snakeCase "${keyVar}" public )=${keyPublic}"
    declare -g "$( var::snakeCase "${keyVar}" private )=${keyPrivate}"
}

: Function to process a key entry
key::process() {
    local keyName="$1"

    : required for updating the backed YAML document variables
    declare -g keyVar
    keyVar="$( var::snakeCase "${profileVarPrefix}" "${keyName}" )"

    declare keyPublic keyPrivate

    : Load the public key if it exists
    keyPublic=$(key::value "public")

    : Load the private key if it exists
    keyPrivate=$(key::value "private")

    : Generate a new key pair if none exists
    if [ -z "$keyPublic" ] && [ -z "$keyPrivate" ]; then
        : Generate new SSH key pair and update global variables
        key::generateKeyPair "$keyName" "$tmpdir"
    fi

    : Sign the key with each authority
    key::signWithAuthorities
}

: Function to generate the YAML output file
keys::toYAML() {

    cat <<EOF | yq -P eval 'explode(...)'
keys:
$(
        local -a signingKeys otherKeys
        declare -g keyVar
        local profileVar keyName
        for profileVar in "${profileVars[@]}"; do
            keyName="$(key::name "$profileVar")"
            if [[ "${signingKeys[*]}" =~ ${keyName} ||
                  "${otherKeys[*]}" =~ ${keyName} ]]; then
                continue
            fi
            keyVar="$( var::snakeCase "${profileVarPrefix}" "${keyName}" )"
            readarray -t keyUsage < <(key::usage)
            local accumulator="otherKeys"
            if [[ "${keyUsage[*]}" =~ user-signing  ]]; then
                accumulator="signingKeys"
            fi
            eval "${accumulator}+=(${keyName})"
        done
        local -a orderedKeys=("${otherKeys[@]}" "${signingKeys[@]}")
        for keyName in "${orderedKeys[@]}"; do
            keyVar="$( var::snakeCase "${profileVarPrefix}" "${keyName}" )"

            local authorityHostNames keyUsage  keyType keyComment keyPublic keyPrivate authorityUsage
            readarray -t keyUsage < <(key::usage)
            keyType=$( key::value type )
            keyComment=$( key::value comment )
            keyPublic=$( key::value public )
            keyPrivate=$( key::value private )
            cat <<EOK
  $keyName: &${keyName}
    usage: $(
                IFS=','
                echo "[ ${keyUsage[*]} ]"
            )
    private: |-
$(echo "$keyPrivate" | sed 's/^/      /')
    public: $keyType $keyPublic $keyComment
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
        if (( ${#processedAuthorities[@]} == 1 )); then
            echo "    certificates:"
        fi
        local authorityVar
        authorityVar="$( var::snakeCase "$keyVar" "authorities" "$authorityName" )"
        echo "      $authorityName:"
        echo "        <<: *$authorityName"
        local authorityUsage
        readarray -t authorityUsage < <(authority::usage "$authorityVar")
        for authorityUsage in "${authorityUsage[@]}"; do
            local certVar
            certVar="$( var::snakeCase "$authorityVar" "$authorityUsage" )"
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

: Main script
declare -g profileName hostName inputFile outputFile
profileName="$1"; shift
hostName="$1"; shift
inputFile="$1"; shift
outputFile="$1"; shift

declare -g osHostname osDomainName
osHostname="$( /bin/hostname -s )"
osDomainName="$( /bin/hostname -d )"

: Create a temporary directory for signing
tmpdir=$(mktemp --directory --suffix=keys.d)
trap 'rm -rf $tmpdir' EXIT

: Load the entire YAML file into shell variables
eval "$(env PROFILE="$profileName" yq -o shell eval 'explode(...) | .profiles.[env(PROFILE)] | { "ssh-keys": . }' "$inputFile")"

declare -g profileVarPrefix
profileVarPrefix=$(var::snakeCase "ssh-keys")

: Collect profile variables
declare -g profileVars
declare -p | grep -oE "${profileVarPrefix}_[^=]+" >"${tmpdir}/profileVars"
readarray -t profileVars <"${tmpdir}/profileVars"

: Process each key entry
declare -g processedKeys=()
for profileVar in "${profileVars[@]}"; do
    keyName="$(key::name "$profileVar")"
    if [[ "${processedKeys[*]}" =~ ${keyName} ]]; then
        : Skip already processed keys
        continue 
    fi
    processedKeys+=("$keyName")
    key::process "$keyName"
done

: Output the updated keys in a YAML file
keys::toYAML >"$outputFile"

exit 0
