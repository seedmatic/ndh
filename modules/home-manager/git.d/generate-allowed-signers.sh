set -euxo pipefail
: Generating github allowed signers configuration file
cat <<EoF > "@allowedSignersFile@"
stephane.lacoin@gmail.com namespaces="git" $( cat "@hostKeysDir@/github-signing.pub" )
stephane.lacoin@hyland.com namespaces="git" $( cat "@hostKeysDir@/github-signing-hyland.pub" )
EoF
