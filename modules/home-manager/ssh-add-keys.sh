#!/usr/bin/env -S bash -exuo pipefail

shopt -s extglob

# Function to handle tracing
log::trace() {
    if [[ -z "${TRACE:=}" ]]; then
        return
    else
        echo "TRACE: $*" >&2
    fi
}

# Function to convert a string to snake_case
var::snakeCase() {
    local var="${1//./_}" &&
        var="${var//-/_}" &&

    if [[ $# -gt 1 ]]; then
        shift
        var+="_$( var::snakeCase "$@" )"
    fi
    echo "${var,,}"
}

# Function to get the private key variable name for an authority
var::authorityPrivateKey() {
    local authorityName="$1"
    var::snakeCase "authorities" "${authorityName}" "private"
}

# Function to get principals for an authority
key::authorityPrincipals() {
    local authorityName principals index
    authority="$1"
    principals=()
    index=0

    while true; do
        local principalVar principal
        principalVar="$( var::snakeCase "${keyVar}" authorities "${authority}" principals "${index}" )"
        principal="${!principalVar:-}"
        if [ -z "$principal" ]; then
            break
        fi
        principals+=("$principal")
        index=$((index + 1))
    done

    ( IFS=, ; echo "${principals[*]}" )
}

# Function to generate a new SSH key pair
key::generateKeyPair() {
    local keyName tmpdir 
    keyName="$1"
    tmpdir="$2"

    local typeVar type
    typeVar="$( var::snakeCase "${keyVar}" type )"
    type="${!typeVar:-ssh-ed25519}"
    type="${type/^ssh-//}"

    local commentVar comment
    commentVar="$( var::snakeCase "${keyVar}" comment )"
    comment="${!commentVar:-${keyName}}"

    # Generate the key pair in a temporary directory
    if ! ssh-keygen -q -t "$type" -N "" -f "${tmpdir}/${keyName}" -C "$comment"; then
        log::trace "Failed to generate key pair for $keyName"
        return 1
    fi

    # Load the generated key pair into global variables
    local keyPublic keyPrivate
    keyPublic="$( cut -d' ' -f2,2 < "${tmpdir}/${keyName}.pub" )" 
    keyPrivate="$( < "${tmpdir}/${keyName}" )"

    # Update the backed YAML document variables
    declare -g "${keyPublicVar}=${keyPublic}"
    declare -g "${keyPrivateVar}=${keyPrivate}"
}

# Function to sign a key with an authority
authority::signKey() {
    local authorityName
    authorityName="$1"

    set | grep keys_ | sort -u
    local keyPublicTypeVar keyPublicCommentVar keyPublicLine
    keyPublicTypeVar="$( var::snakeCase "$keyVar" "type" )"
    keyPublicCommentVar="$( var::snakeCase "$keyVar" "comment" )"
    keyPublicLine="${!keyPublicTypeVar} ${!keyPublicVar} ${!keyPublicCommentVar}"

    local caKeyPrivateVar caKeyPrivate
    caKeyPrivateVar=$( var::authorityPrivateKey "$authorityName" )
    caKeyPrivate="${!caKeyPrivateVar}"
    if [ -z "$caKeyPrivate" ]; then
        return
    fi

    # Create temporary files for the private key and public key
    local keyPrivateTmpFile keyPublicTmpFile
    keyPrivateTmpFile="${tmpdir}/${authorityName}"
    keyPublicTmpFile="${tmpdir}/${keyName}-cert.pub"
    trap "trap - RETURN; rm -f $keyPrivateTmpFile $keyPublicTmpFile" RETURN

    cat <<<"$caKeyPrivate" > "$keyPrivateTmpFile" && 
      chmod 400 "$keyPrivateTmpFile"
    cat <<<"${!keyPublicVar}" > "$keyPublicTmpFile"
    cat <<<"${keyPublicLine}" > "$keyPublicTmpFile"

    # Get the allowed principals foqr the key
    local principals
    principals=$( key::authorityPrincipals "$authorityName" )

    # Sign the key
    if ! ssh-keygen -q -s "$keyPrivateTmpFile" -I "${keyName}" -n "$principals" "$keyPublicTmpFile"; then
        log::trace "Failed to sign key with authority $authorityName"
        cat "$keyPublicTmpFile"
        cat "$keyPrivateTmpFile"
        return 1
    fi

    # Update the backed YAML document variables
    declare -g "${keyPublicVar}=$( cut -d' ' -f2,2 < "$keyPublicTmpFile" )"
}

# Function to sign a key with all authorities
key::signWithAuthorities() {
    local signedAuthorities=()

    for profileVar in "${profileVars[@]}"; do
        if ! [[ "$profileVar" =~ ^${keyVar}_authorities_  ]]; then
            continue
        fi

        # Extract the authority name from the variable
        local authorityName
        authorityName=${profileVar##*_authorities_}
        authorityName=${authorityName%%_principals_[0-9+]} # remove the index
        # Check if the authority has already been signed
        if [[ "${signedAuthorities[*]}" =~ ${authorityName} ]]; then
            continue
        fi

        # Sign the key with the authority
        authority::signKey "${authorityName}"

        # Add the authority to the list of signed authorities
        signedAuthorities+=("$authorityName")
    done
}

key::name() {
    local keyVar
    keyVar="$1"

    # Remove the prefix
    keyName=${keyVar#"${profileVarPrefix}_"}

    # Remove any suffix starting from the specified words
    keyName=${keyName%%_@(comment|type|public|private|authorities)*}

    echo "$keyName"
}

# Function to process a key entry
key::process() {
    local keyName="$1"

    declare -g "keyVar=${profileVarPrefix}_${keyName}"

    declare -g keyPublicVar keyPrivateVar  # required for updating the backed YAML document
    declare keyPublic keyPrivate

    # Load the public key if it exists
    keyPublicVar="${keyVar}_public"
    keyPublic=${!keyPublicVar:-}

    # Load the private key if it exists
    keyPrivateVar="${keyVar}_private"
    keyPrivate=${!keyPrivateVar:-}

    # Generate a new key pair if none exists
    if [ -z "$keyPublic" ] && [ -z "$keyPrivate" ]; then
        # Generate new SSH key pair and update global variables
        key::generateKeyPair "$keyName" "$tmpdir"
    fi

    # Sign the key with each authority
    key::signWithAuthorities
}

# Function to generate the YAML output file
keys::toYAML() {
    cat <<EOF | yq -P eval .
keys:
$( 
  set -x
  processedKeys=()
  for profileVar in "${profileVars[@]}"; do
    keyName="$( key::name "$profileVar")"

    if [[ "${processedKeys[*]}" =~ ${keyName} ]]; then
        continue
    fi
    processedKeys+=("$keyName")
    
    keyVar="${profileVarPrefix}_${keyName}"

    keyTypeVar=$( var::snakeCase "${keyVar}" type )
    keyType=${!keyTypeVar:-ssh-ed25519}

    keyCommentVar=$( var::snakeCase "${keyVar}" comment )
    keyComment=${!keyCommentVar:-$keyName}
    
    keyPublicVar=$( var::snakeCase "${keyVar}" public )
    keyPublic=${!keyPublicVar}
    
    keyPrivateVar=$( var::snakeCase "${keyVar}" private )
    keyPrivate=${!keyPrivateVar}

    cat <<EOK
  $keyName:
    type: ${keyType}
    comment: ${keyComment}
    public: $keyPublic
    private: |-
$( echo "$keyPrivate" | sed 's/^/      /' )
EOK
done )
EOF
}

# Main script
inputFile="$1"
outputFile="$2"
profileName="$3"

# Create a temporary directory for signing
tmpdir=$( mktemp --directory --suffix=keys.d )
trap 'rm -rf $tmpdir' EXIT

# Load the entire YAML file into shell variables
eval "$( env PROFILE="$profileName" yq -o shell eval 'explode(...) | .profiles.[env(PROFILE)]' "$inputFile" )"

profileVarPrefix=$( var::snakeCase "keys" )

# Collect profile variables
declare -p | grep -oE "${profileVarPrefix}_[^=]+" > "${tmpdir}/profileVars"
mapfile -t profileVars < "${tmpdir}/profileVars"

# Process each key entry
declare -g processedKeys=( )
for profileVar in "${profileVars[@]}"; do
    keyName="$( key::name "$profileVar" )"
    if [[ "${processedKeys[*]}" =~ ${keyName} ]]; then
        continue # Skip already processed keys
    fi
    processedKeys+=("$keyName")
    key::process "$keyName"
done

# Output the updated keys in a YAML file
keys::toYAML > "$outputFile"
