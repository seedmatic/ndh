#!@bashBin@
set -euo pipefail

out_dir="${1:?missing output directory}"

cp -r --no-preserve=mode,ownership "@baseConfigDir@" "${out_dir}"
chmod -R u+w "${out_dir}"

"@perlBin@" "@patchAuthScript@" "${out_dir}/system.conf"
"@perlBin@" "@patchPolicyScript@" "${out_dir}/system.conf"

chmod -R a-w "${out_dir}"
