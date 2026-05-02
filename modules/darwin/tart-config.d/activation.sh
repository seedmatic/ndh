#!/usr/bin/env -S bash -euo pipefail
# shellcheck source=/dev/null
# shellcheck disable=SC2016
# SC2016: yq expressions use single quotes intentionally (not bash variable expansion)
source @nixBashTrampoline@

tart:bool:is-true() {
	local value="${1:-}"
	value="${value,,}"
	[[ "$value" == "1" || "$value" == "true" || "$value" == "yes" || "$value" == "on" ]]
}

tart:image:virtual-size-bytes() {
	local image_path="$1"
	local total_bytes=""

	if [[ ! -f "$image_path" ]]; then
		return 1
	fi

	if [[ -z "${diskutil_bin:-}" ]]; then
		diskutil_bin="/usr/sbin/diskutil"
	fi

	total_bytes="$(
		"$diskutil_bin" image info --plist "$image_path" 2>/dev/null |
			yq -p=xml -r '
				.plist.dict.dict[] |
				select((.key? | type) == "!!seq") |
				(.key | to_entries[] | select(.value == "Total Bytes") | .key) as $k |
				.integer[$k]
			'
	)"

	if [[ ! "$total_bytes" =~ ^[0-9]+$ ]]; then
		return 1
	fi

	printf '%s\n' "$total_bytes"
}

tart:image:size:matches-source() {
	# tart:image:size:matches-source <source_img> <target_img>
	local source_img="$1"
	local target_img="$2"
	local source_bytes=""
	local target_bytes=""

	[[ -f "$source_img" && -f "$target_img" ]] || return 1

	source_bytes="$(tart:image:virtual-size-bytes "$source_img" 2>/dev/null || true)"
	target_bytes="$(tart:image:virtual-size-bytes "$target_img" 2>/dev/null || true)"

	[[ "$source_bytes" =~ ^[0-9]+$ ]] || return 1
	[[ "$target_bytes" =~ ^[0-9]+$ ]] || return 1

	[[ "$source_bytes" == "$target_bytes" ]]
}

tart:image:resize-if-smaller() {
	# tart:image:resize-if-smaller <image_path> <target_gib> [log_label]
	local image_path="$1"
	local target_gib="$2"
	local log_label="${3:-disk}"
	local desired_bytes=0
	local current_bytes=""
	local log_prefix="${TART_LOG_PREFIX:-[tart]}"

	if [[ ! -f "$image_path" ]]; then
		echo "${log_prefix}[ERROR] cannot resize missing image: $image_path" >&2
		return 1
	fi

	if [[ ! "$target_gib" =~ ^[0-9]+$ ]] || ((target_gib <= 0)); then
		echo "${log_prefix}[ERROR] invalid target size (GiB) for ${log_label}: $target_gib" >&2
		return 1
	fi

	# diskutil `--size <N>g` uses decimal gigabytes (10^9 bytes), not GiB.
	desired_bytes=$((target_gib * 1000 * 1000 * 1000))
	current_bytes="$(tart:image:virtual-size-bytes "$image_path" 2>/dev/null || true)"

	if [[ ! "$current_bytes" =~ ^[0-9]+$ ]]; then
		echo "${log_prefix}[ERROR] unable to read current size for ${log_label}: $image_path" >&2
		return 1
	fi

	if ((current_bytes < desired_bytes)); then
		echo "${log_prefix}[INFO] expanding ${log_label} to ${target_gib}GiB: $image_path (currentBytes=$current_bytes targetBytes=$desired_bytes)" >&2
		if ! sudo "$diskutil_bin" image resize --plist --size "${target_gib}g" "$image_path" >&2; then
			echo "${log_prefix}[ERROR] failed to resize ${log_label} to ${target_gib}GiB: $image_path" >&2
			return 1
		fi
	elif ((current_bytes > desired_bytes)); then
		echo "${log_prefix}[INFO] ${log_label} already larger than target; keeping existing size: $image_path (currentBytes=$current_bytes targetBytes=$desired_bytes)" >&2
	else
		echo "${log_prefix}[INFO] ${log_label} already at target size; no resize needed: $image_path (currentBytes=$current_bytes targetBytes=$desired_bytes)" >&2
	fi

	chmod 0644 "$image_path" 2>/dev/null || true
	if [[ "$(id -u)" -eq 0 ]] && [[ -n "${profile_group:-}" ]] && [[ "$image_path" == "${effective_home:-}/"* ]]; then
		chown "${profile_user}:${profile_group}" "$image_path" 2>/dev/null || true
	fi

	return 0
}

tart:root-disk:zfs:contains() {
	local disk="$1"
	local partition_hints=""
	local partition_names=""
	local hint=""
	local part_name=""
	local zfs_label_regex="${TART_ROOT_DISK_ZFS_LABEL_REGEX:-^(tank1|tank2|tank3|recover)$}"
	local log_prefix="${TART_LOG_PREFIX:-[tart]}"

	if [[ ! -f "$disk" ]]; then
		echo "${log_prefix}[WARN] root disk missing for ZFS introspection: ${disk}" >&2
		return 1
	fi

	if [[ -z "${diskutil_bin:-}" ]]; then
		diskutil_bin="/usr/sbin/diskutil"
	fi

	partition_hints="$({
		"$diskutil_bin" image info --plist "$disk" 2>/dev/null |
			yq -p=xml '
				.plist.dict.array.dict[] |
				select(.key[] == "content-hint") |
				(.key | to_entries[] | select(.value == "content-hint") | .key) as $k |
				.string[$k]
			' 2>/dev/null
	} || true)"

	partition_names="$({
		"$diskutil_bin" image info --plist "$disk" 2>/dev/null |
			yq -p=xml '
				.plist.dict.array.dict[] |
				select(.key[] == "name") |
				(.key | to_entries[] | select(.value == "name") | .key) as $k |
				.string[$k]
			' 2>/dev/null
	} || true)"

	if [[ -z "$partition_hints" && -z "$partition_names" ]]; then
		return 1
	fi

	while IFS= read -r hint; do
		hint="${hint,,}"
		if [[ "$hint" == *"zfs"* || "$hint" == *"solaris"* ]]; then
			return 0
		fi
	done <<< "$partition_hints"

	while IFS= read -r part_name; do
		part_name="${part_name,,}"
		if [[ "$part_name" =~ $zfs_label_regex ]]; then
			echo "${log_prefix}[INFO] root disk ZFS signature detected from partition label: ${part_name}" >&2
			return 0
		fi
	done <<< "$partition_names"

	return 1
}

tart:bootstrap:manifest:bootloader:validate() {
	# tart:bootstrap:manifest:bootloader:validate <manifest_path> <expected_boot_loader>
	local manifest_path="${1:-}"
	local expected_boot_loader="${2:-}"
	local actual_boot_loader=""
	local log_prefix="${TART_LOG_PREFIX:-[tart]}"

	if [[ -z "$manifest_path" || -z "$expected_boot_loader" ]]; then
		return 0
	fi

	if [[ ! -r "$manifest_path" ]]; then
		echo "${log_prefix}[ERROR] configured bootstrap disk manifest missing/unreadable: $manifest_path" >&2
		return 1
	fi

	actual_boot_loader="$(yq -p=yaml -r '.bootLoader // ""' "$manifest_path" 2>/dev/null || true)"
	if [[ -z "$actual_boot_loader" ]]; then
		echo "${log_prefix}[ERROR] unable to resolve bootLoader from bootstrap disk manifest: $manifest_path" >&2
		return 1
	fi

	if [[ "$actual_boot_loader" != "$expected_boot_loader" ]]; then
		echo "${log_prefix}[ERROR] bootstrap disk bootLoader mismatch: expected=$expected_boot_loader actual=$actual_boot_loader manifest=$manifest_path" >&2
		return 1
	fi

	echo "${log_prefix}[INFO] bootstrap disk manifest bootLoader validated: ${actual_boot_loader} (${manifest_path})" >&2
	return 0
}

tart:bootstrap:disk:sync-from-source() {
	# tart:bootstrap:disk:sync-from-source <source_img> <target_img> [size_gib] [owner_user] [owner_group] [owner_home]
	local source_path="${1:-}"
	local target_path="${2:-}"
	local size_gib="${3:-24}"
	local owner_user="${4:-}"
	local owner_group="${5:-}"
	local owner_home="${6:-}"
	local desired_bytes=0
	local current_bytes=""
	local log_prefix="${TART_LOG_PREFIX:-[tart]}"

	if [[ -z "$source_path" || -z "$target_path" ]]; then
		echo "${log_prefix}[ERROR] bootstrap disk sync requires source and target paths" >&2
		return 1
	fi

	if [[ ! -f "$source_path" ]]; then
		echo "${log_prefix}[ERROR] configured bootstrap source image missing/unreadable: $source_path" >&2
		return 1
	fi

	if [[ ! "$size_gib" =~ ^[0-9]+$ ]] || ((size_gib <= 0)); then
		echo "${log_prefix}[ERROR] invalid bootstrap disk size (GiB): $size_gib" >&2
		return 1
	fi

	mkdir -p "$(dirname "$target_path")"

	if [[ ! -f "$target_path" ]] || ! cmp -s "$source_path" "$target_path"; then
		echo "${log_prefix}[INFO] syncing VM-local bootstrap disk from source image: $source_path -> $target_path" >&2
		cp -f "$source_path" "$target_path"
	fi

	# diskutil `--size <N>g` uses decimal gigabytes (10^9 bytes), not GiB.
	desired_bytes=$((size_gib * 1000 * 1000 * 1000))
	current_bytes="$(tart:image:virtual-size-bytes "$target_path" 2>/dev/null || true)"
	if [[ ! "$current_bytes" =~ ^[0-9]+$ ]]; then
		echo "${log_prefix}[ERROR] unable to read VM-local bootstrap disk size: $target_path" >&2
		return 1
	fi

	if ((current_bytes < desired_bytes)); then
		echo "${log_prefix}[INFO] expanding VM-local bootstrap disk to ${size_gib}GiB: $target_path (currentBytes=$current_bytes targetBytes=$desired_bytes)" >&2
		if ! sudo diskutil image resize --plist --size "${size_gib}g" "$target_path" >&2; then
			echo "${log_prefix}[ERROR] failed to resize VM-local bootstrap disk to ${size_gib}GiB: $target_path" >&2
			return 1
		fi
	else
		echo "${log_prefix}[INFO] VM-local bootstrap disk already at target size; no resize needed: $target_path (currentBytes=$current_bytes targetBytes=$desired_bytes)" >&2
	fi

	chmod 0644 "$target_path" 2>/dev/null || true
	if [[ "$(id -u)" -eq 0 ]] && [[ -n "$owner_user" ]] && [[ -n "$owner_group" ]] && [[ -n "$owner_home" ]] && [[ "$target_path" == "${owner_home}/"* ]]; then
		chown "${owner_user}:${owner_group}" "$target_path" 2>/dev/null || true
	fi

	return 0
}

main() {
	set -euo pipefail

	local manifest_path=""
	local tart_nix_cli_args_raw=""
	local tart_factory_reset_raw=""
	local profile_user=""
	local profile_group=""
	local gcroot_user=""
	local gcroot_group=""
	local factory_reset=0
	local configured_home=""
	local effective_host_name=""

	tart:state:init() {
		manifest_path="@manifestPath@"
		tart_nix_cli_args_raw="${NIX_CLI_ARGS:--L -v -v}"
		tart_factory_reset_raw="${FACTORY_RESET:-0}"
		profile_user=""
		profile_group=""
		gcroot_user=""
		gcroot_group=""
		factory_reset=0
		configured_home=""
		effective_host_name=""
	}

	tart:manifest:load() {
		if [[ ! -r "$manifest_path" ]]; then
			: "[tartConfig][ERROR] activation manifest missing/unreadable: ${manifest_path}"
			exit 1
		fi

		if ! command -v yq >/dev/null 2>&1; then
			: "[tartConfig][ERROR] yq is required to parse activation manifest: ${manifest_path}"
			exit 1
		fi

		# shellcheck disable=SC1090
		source <(yq -p=yaml -o=shell '.' "$manifest_path")
	}

	tart:manifest:images:enumerate() {
		# Yields: <name>\t<role> for every disk image in the bringup manifest.
		# Tries .images[] first; falls back to scanning the manifest directory when the
		# array is empty (e.g. cached builds from before the images loop was added).
		local manifest_path="${raw_image_manifest_path:-${raw_image_manifest_path_default:-}}"
		local primary_img primary_name manifest_dir image_count img_file img_name img_role
		[[ -n "$manifest_path" && -r "$manifest_path" ]] || return 0

		primary_img="$(yq -p=yaml -r '.imagePath // ""' "$manifest_path" 2>/dev/null || true)"
		primary_name="${primary_img%.img}"
		manifest_dir="$(dirname "$manifest_path")"
		image_count="$(yq -p=yaml -r '.images | length' "$manifest_path" 2>/dev/null || echo 0)"

		if ((image_count > 0)); then
			yq -p=yaml -r '.images[]? | [(.name // ""), (.role // "")] | @tsv' "$manifest_path"
			return
		fi

		# Fallback: scan manifest directory for *.img files (symlinks or regular files)
		while IFS= read -r img_file; do
			img_name="$(basename "$img_file" .img)"
			if [[ -n "$primary_name" && "$img_name" == "$primary_name" ]]; then
				img_role="primary"
			else
				img_role=""
			fi
			printf '%s\t%s\n' "$img_name" "$img_role"
		done < <(find "$manifest_dir" -maxdepth 1 \( -type f -o -type l \) -name '*.img' 2>/dev/null | LC_ALL=C sort)
	}

	tart:disks:from-manifest:init() {
		local image_name image_role
		tart_vm_data_disks=()

		while IFS=$'\t' read -r image_name image_role; do
			[[ -n "$image_name" ]] || continue
			[[ "$image_role" != "primary" ]] || continue
			tart_vm_data_disks+=("${tart_vm_dir}/${image_name}.img")
		done < <(tart:manifest:images:enumerate)

		if [[ ${#tart_vm_data_disks[@]} -eq 0 ]]; then
			: "[tartConfig][WARN] no data disks resolved from manifest; using default ZFS disk layout"
			tart_vm_data_disks=(
				"${tart_vm_dir}/tank1.img"
				"${tart_vm_dir}/tank2.img"
				"${tart_vm_dir}/tank3.img"
				"${tart_vm_dir}/recover.img"
			)
		fi
	}

	tart:fs:path:relink() {
		local src="$1"
		local dst="$2"
		local label="$3"

		if [ -d "$dst" ] && [ ! -L "$dst" ]; then
			: "[tartConfig][WARN] ${label} destination is a directory; removing to restore symlink semantics: $dst"
			rm -rf "$dst"
		fi

		rm -f "$dst"
		ln -s "$src" "$dst"

		if [ -L "$dst" ]; then
			if [[ "$dst" == "/nix/var/nix/gcroots/per-user/${gcroot_user}/"* ]] && [[ "$(id -u)" -eq 0 ]] && [[ -n "$gcroot_group" ]]; then
				chown -h "${gcroot_user}:${gcroot_group}" "$dst" 2>/dev/null || true
			fi
			: "${label}: $dst -> $(readlink "$dst" || echo '<not-a-symlink>')"
			return 0
		fi

		: "[tartConfig][ERROR] ${label} destination is not a symlink after update: $dst"
		return 1
	}

	tart:fs:dir:ensure() {
		local dir="$1"
		local mode="${2:-0755}"

		if [[ "$(id -u)" -eq 0 ]] && [[ -n "$gcroot_group" ]] && [[ "$dir" == "/nix/var/nix/gcroots/per-user/${gcroot_user}"* ]]; then
			install -d -m "$mode" -o "$gcroot_user" -g "$gcroot_group" "$dir"
		else
			install -d -m "$mode" "$dir"
		fi
	}

	tart:runtime:home:resolve() {
		effective_home="$configured_home"
		runtime_user="$(id -un)"
		runtime_home="${HOME:-}"

		if [ ! -d "$effective_home" ]; then
			if [ -n "$runtime_home" ] && [ -d "$runtime_home" ]; then
				: "[tartConfig][WARN] configured profile home missing: $configured_home; using HOME for runtime user $runtime_user: $runtime_home"
				effective_home="$runtime_home"
			else
				discovered_home="$(
					dscl . -read "/Users/${runtime_user}" NFSHomeDirectory -plist 2>/dev/null |
						yq -p=xml -r '.plist.dict.array.string // ""' 2>/dev/null ||
						true
				)"
				if [ -n "$discovered_home" ] && [ -d "$discovered_home" ]; then
					: "[tartConfig][WARN] configured profile home missing: $configured_home; using runtime home from dscl for $runtime_user: $discovered_home"
					effective_home="$discovered_home"
				else
					: "[tartConfig][WARN] configured profile home missing and runtime home discovery failed; keeping configured path: $configured_home"
				fi
			fi
		fi
	}

	tart:runtime:tooling:validate() {
		if ! command -v tart >/dev/null 2>&1; then
			: "[tartConfig][ERROR] tart CLI is not available in PATH; cannot materialize VM"
			: "[tartConfig][ERROR] tartBinaryPath hint=$tart_binary_hint"
			exit 1
		fi

		if ! command -v yq >/dev/null 2>&1; then
			: "[tartConfig][ERROR] yq is not available in PATH; cannot patch tart config JSON"
			exit 1
		fi
	}

	tart:runtime:path:setup() {
		PATH="$(dirname "$tart_binary_hint"):$(dirname "$diskutil_bin"):/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"
		export PATH
	}

	tart:gcroot:path:rewrite-user() {
		local path="$1"
		if [[ "$path" =~ ^/nix/var/nix/gcroots/per-user/([^/]+)/(.+)$ ]]; then
			local path_user="${BASH_REMATCH[1]}"
			local path_tail="${BASH_REMATCH[2]}"
			if [[ -n "$gcroot_user" && "$path_user" != "$gcroot_user" ]]; then
				echo "/nix/var/nix/gcroots/per-user/${gcroot_user}/${path_tail}"
				return 0
			fi
		fi
		echo "$path"
	}

	tart:raw-image:resolve-from-manifest() {
		# tart:raw-image:resolve-from-manifest <manifest_path>
		# stdout lines: <name>\t<resolved_abs_path>\t<role>
		local manifest_path="$1"
		local manifest_dir=""
		local source_out=""
		local image_name=""
		local image_path=""
		local image_role=""
		local resolved=""
		local primary_img=""
		local primary_name=""
		local image_count=0

		[[ -n "$manifest_path" && -r "$manifest_path" ]] || return 0

		manifest_dir="$(dirname "$manifest_path")"
		source_out="$(yq -p=yaml -r '.sourceOutPath // ""' "$manifest_path" 2>/dev/null || true)"
		primary_img="$(yq -p=yaml -r '.imagePath // ""' "$manifest_path" 2>/dev/null || true)"
		primary_name="${primary_img%.img}"
		image_count="$(yq -p=yaml -r '.images | length' "$manifest_path" 2>/dev/null || echo 0)"

		if ((image_count > 0)); then
			while IFS=$'\t' read -r image_name image_path image_role; do
				[[ -n "$image_path" ]] || continue
				resolved=""
				if [[ "$image_path" = /* ]]; then
					resolved="$image_path"
				elif [[ -f "${manifest_dir}/${image_path}" ]]; then
					resolved="${manifest_dir}/${image_path}"
				elif [[ -n "$source_out" && -f "${source_out}/${image_path}" ]]; then
					resolved="${source_out}/${image_path}"
				fi
				if [[ -n "$resolved" && -f "$resolved" ]]; then
					printf '%s\t%s\t%s\n' "$image_name" "$resolved" "$image_role"
				fi
			done < <(yq -p=yaml -r '.images[]? | [(.name // ""), (.path // ""), (.role // "")] | @tsv' "$manifest_path" 2>/dev/null || true)
			return 0
		fi

		# Fallback: images[] is empty (old manifest build) — scan the manifest directory
		# and sourceOutPath for *.img files. Use .imagePath to identify the primary.
		local img_file img_basename img_name img_role_out
		while IFS= read -r img_file; do
			img_basename="$(basename "$img_file")"
			img_name="${img_basename%.img}"
			if [[ -n "$primary_name" && "$img_name" == "$primary_name" ]]; then
				img_role_out="primary"
			else
				img_role_out=""
			fi
			printf '%s\t%s\t%s\n' "$img_name" "$img_file" "$img_role_out"
		done < <(
			{
				find "$manifest_dir" -maxdepth 1 \( -type f -o -type l \) -name '*.img' 2>/dev/null
				if [[ -n "$source_out" && -d "$source_out" ]]; then
					find "$source_out" -maxdepth 1 \( -type f -o -type l \) -name '*.img' 2>/dev/null
				fi
			} | LC_ALL=C sort -u
		)
	}

	tart:raw-images:gcroot:materialize() {
		# Create a single gcroot symlink pointing to the materialize bundle directory.
		# The bundle (bin/activate.sh + bringup-manifest → bringup images store dir)
		# keeps the entire disk-image closure alive through one gcroot link.
		# Both run.sh and activation.sh resolve bringup images via
		# ${gcroot}/bringup-manifest/manifest.yaml at runtime.
		local target_path="${raw_image_target_path:-}"

		[[ -n "$target_path" ]] || return 0

		target_path="$(tart:gcroot:path:rewrite-user "$target_path")"
		tart:fs:dir:ensure "$(dirname "$target_path")" 0755

		# BASH_SOURCE[0] = /nix/store/hash.../bin/activate.sh inside the bundle dir.
		local bundle_dir
		bundle_dir="$(dirname "$(dirname "${BASH_SOURCE[0]}")")"
		tart:fs:path:relink "$bundle_dir" "$target_path" "materialize app gcroot"

		# Remove stale per-image sibling links that the old per-file strategy created
		# alongside the primary gcroot (e.g. tart-nerd-nixos.tank1.raw.img, …).
		local gcroot_dir sibling_base
		gcroot_dir="$(dirname "$target_path")"
		sibling_base="${target_path%.img}"
		sibling_base="${sibling_base%.raw}"
		while IFS= read -r -d '' stale; do
			: "[tartConfig][INFO] removing stale per-image gcroot: $stale"
			rm -f "$stale"
		done < <(find "$gcroot_dir" -maxdepth 1 -name "$(basename "$sibling_base").*.raw.img" -print0 2>/dev/null || true)
	}

	tart:raw-image:path:from-manifest() {
		# tart:raw-image:path:from-manifest <image_name|primary>
		local wanted="$1"
		local manifest_path="${raw_image_manifest_path:-}"
		local image_name=""
		local image_src=""
		local image_role=""

		[[ -n "$manifest_path" && -r "$manifest_path" ]] || return 1

		while IFS=$'\t' read -r image_name image_src image_role; do
			[[ -n "$image_src" ]] || continue
			if [[ "$wanted" == "primary" ]]; then
				if [[ "$image_role" == "primary" ]]; then
					printf '%s\n' "$image_src"
					return 0
				fi
			elif [[ "$image_name" == "$wanted" ]]; then
				printf '%s\n' "$image_src"
				return 0
			fi
		done < <(tart:raw-image:resolve-from-manifest "$manifest_path")

		return 1
	}

	tart:raw-image:manifest:auto-resolve() {
		# If manifest path is not explicitly configured, infer it from the gcroot bundle or
		# from raw image store/source paths.
		local candidate=""

		if [[ -n "${raw_image_manifest_path:-}" && -r "${raw_image_manifest_path:-}" ]]; then
			return 0
		fi

		# Primary: follow the gcroot bundle (bin/activate.sh lives two levels deep inside it).
		local bundle_dir
		bundle_dir="$(dirname "$(dirname "${BASH_SOURCE[0]}")")"
		candidate="${bundle_dir}/bringup-manifest/manifest.yaml"
		if [[ -r "$candidate" ]]; then
			raw_image_manifest_path="$candidate"
			: "[tartConfig][INFO] auto-resolved raw image manifest from bundle: $raw_image_manifest_path"
			return 0
		fi

		if [[ -n "${raw_image_store_path:-}" && -f "${raw_image_store_path:-}" ]]; then
			candidate="$(dirname "${raw_image_store_path}")/manifest.yaml"
			if [[ -r "$candidate" ]]; then
				raw_image_manifest_path="$candidate"
				: "[tartConfig][INFO] auto-resolved raw image manifest from store path: $raw_image_manifest_path"
				return 0
			fi
		fi

		if [[ -n "${raw_image_source_path:-}" && -f "${raw_image_source_path:-}" ]]; then
			candidate="$(dirname "${raw_image_source_path}")/manifest.yaml"
			if [[ -r "$candidate" ]]; then
				raw_image_manifest_path="$candidate"
				: "[tartConfig][INFO] auto-resolved raw image manifest from source path: $raw_image_manifest_path"
				return 0
			fi
		fi
	}

	tart:disk:image:materialize-from-source() {
		# tart:disk:image:materialize-from-source <source_img> <target_img> <label>
		local source_img="$1"
		local target_img="$2"
		local label="${3:-disk}"

		if [[ -z "$source_img" || -z "$target_img" ]]; then
			: "[tartConfig][ERROR] image materialization requires source and target paths"
			exit 1
		fi

		if [[ ! -f "$source_img" ]]; then
			: "[tartConfig][ERROR] image materialization source is missing: $source_img"
			exit 1
		fi

		if [[ -f "$target_img" ]] && cmp -s "$source_img" "$target_img"; then
			: "[tartConfig][INFO] ${label} already matches source image; keeping target: $target_img"
			return 0
		fi

		mkdir -p "$(dirname "$target_img")"
		rm -f "$target_img" >/dev/null 2>&1 || true

		if [[ "${vm_disk_format:-asif}" == "asif" ]]; then
			: "[tartConfig][INFO] materializing ${label} from manifest image via ASIF conversion: $source_img -> $target_img"
			diskutil image create from --format ASIF "$source_img" "$target_img" >/dev/null
		else
			: "[tartConfig][INFO] materializing ${label} from manifest image via raw copy: $source_img -> $target_img"
			cp -f "$source_img" "$target_img"
		fi

		chmod 0644 "$target_img" 2>/dev/null || true
		if [[ "$(id -u)" -eq 0 ]] && [[ -n "$profile_group" ]] && [[ "$target_img" == "${effective_home}/"* ]]; then
			chown "${profile_user}:${profile_group}" "$target_img" 2>/dev/null || true
		fi
	}

	tart:vm:run() {
		tart "$@"
	}

	tart:vm:exists() {
		local vm="$1"
		local listed_vm
		while read -r listed_vm _; do
			if [[ "$listed_vm" == "$vm" ]]; then
				return 0
			fi
		done < <(tart:vm:run list 2>/dev/null)
		return 1
	}

	tart:vm:ensure() {
		local vm="$1"
		local disk_size="$2"
		local disk_format="$3"

		if tart:vm:exists "$vm"; then
			: "tart VM already exists: $vm"
			return 0
		fi
		
		: "creating tart VM: $vm (os=linux disk-size=${disk_size}GiB disk-format=${disk_format})"
		tart:vm:run create "$vm" --linux --disk-size "$disk_size" --disk-format "$disk_format"
		tart:vm:disks:ensure:blank
	}

	tart:vm:recreate() {
		local vm="$1"
		local disk_size="$2"
		local disk_format="$3"

		tart:vm:run stop "$vm" >/dev/null 2>&1 || true

		if tart:vm:exists "$vm"; then
			: "recreating tart VM: $vm"
			tart:vm:run delete "$vm" >/dev/null 2>&1 || true
		fi

		rm -rf "${effective_home}/.tart/vms/${vm}" 2>/dev/null || true

		: "creating tart VM: $vm (os=linux disk-size=${disk_size}GiB disk-format=${disk_format})"
		tart:vm:run create "$vm" --linux --disk-size "$disk_size" --disk-format "$disk_format"
	}

	tart:vm:data-disk:create-asif() {
		local disk="$1"
		local size_gib="$2"

		if [[ ! "$size_gib" =~ ^[0-9]+$ ]] || ((size_gib <= 0)); then
			: "[tartConfig][ERROR] invalid data disk size (GiB): $size_gib"
			exit 1
		fi

		rm -f "${disk}" >/dev/null 2>&1 || true

		: "creating blank ASIF data disk: $disk (${size_gib}GiB)"
		diskutil image create blank --plist --fs None --size "${size_gib}g" --format ASIF "$disk" >&2 || { 
			: "[tartConfig][ERROR] diskutil failed to create ASIF data disk: $disk"; exit 1; 
		}


		if [ -z "$disk" ]; then
			: "[tartConfig][ERROR] diskutil produced no ASIF data disk output for: $disk"
			exit 1
		fi

		if [ ! -f "$disk" ]; then
			: "[tartConfig][ERROR] failed to create ASIF data disk: $disk"
			exit 1
		fi

		chmod 0644 "$disk" 2>/dev/null || true
		if [[ "$(id -u)" -eq 0 ]] && [[ -n "$profile_group" ]] && [[ "$disk" == "${effective_home}/"* ]]; then
			chown "${profile_user}:${profile_group}" "$disk" 2>/dev/null || true
		fi
	}


	tart:vm:disks:ensure:blank() {
		tart:fs:dir:ensure "$tart_vm_dir" 0755
		for disk in "${tart_vm_data_disks[@]}"; do
			: "creating blank data disk during activation: $disk (${data_disk_size_gib}GiB, ASIF)"
			tart:vm:data-disk:create-asif "$disk" "$data_disk_size_gib"
		done
	}

	tart:vm:data-disks:size:enforce() {
		local disk=""
		local manifest_image_name=""
		local manifest_source=""

		for disk in "${tart_vm_data_disks[@]}"; do
			manifest_image_name="$(basename "$disk" .img)"
			manifest_source=""

			if [[ -n "$manifest_image_name" ]]; then
				manifest_source="$(tart:raw-image:path:from-manifest "$manifest_image_name" 2>/dev/null || true)"
			fi

			if [[ -n "$manifest_source" ]]; then
				if [[ ! -f "$disk" ]] || ! tart:root-disk:zfs:contains "$disk"; then
					tart:disk:image:materialize-from-source "$manifest_source" "$disk" "${manifest_image_name} data disk"
				elif ! tart:image:size:matches-source "$manifest_source" "$disk"; then
					: "[tartConfig][WARN] ZFS ${manifest_image_name} data disk size mismatch vs manifest source; rematerializing from source"
					tart:disk:image:materialize-from-source "$manifest_source" "$disk" "${manifest_image_name} data disk"
				else
					: "[tartConfig][INFO] preserving existing ZFS ${manifest_image_name} data disk: $disk"
				fi
				continue
			fi

			if [[ ! -f "$disk" ]]; then
				: "[tartConfig][WARN] missing data disk; creating canonical blank ASIF (${data_disk_size_gib}GiB): $disk"
				tart:vm:data-disk:create-asif "$disk" "$data_disk_size_gib"
				continue
			fi

			# If disk exists but has no ZFS, it's either blank or has a corrupt/partial partition
			# table from a previous failed bringup. Reset to a clean blank ASIF so the next
			# bringup starts from a known-good state.
			if ! tart:root-disk:zfs:contains "$disk"; then
				: "[tartConfig][INFO] data disk has no ZFS (blank or failed bringup); recreating as clean blank ASIF (${data_disk_size_gib}GiB): $disk"
				tart:vm:data-disk:create-asif "$disk" "$data_disk_size_gib"
				continue
			fi

			TART_LOG_PREFIX="[tartConfig]"
			if ! tart:image:resize-if-smaller "$disk" "$data_disk_size_gib" "data disk"; then
				: "[tartConfig][WARN] data disk resize failed; recreating canonical blank ASIF (${data_disk_size_gib}GiB): $disk"
				tart:vm:data-disk:create-asif "$disk" "$data_disk_size_gib"
			fi
		done
	}

	tart:vm:factory-reset:apply() {
		if ((factory_reset == 0)); then
			return 0
		fi

		: "[tartConfig][WARN] factory reset requested (FACTORY_RESET=${tart_factory_reset_raw})"
		: "[tartConfig][WARN] removing existing Tart root/data images before recreation"

		tart:vm:run stop "$vm_name" >/dev/null 2>&1 || true
		if tart:vm:exists "$vm_name"; then
			: "[tartConfig][INFO] deleting existing VM definition to force root disk recreation via tart create"
			tart:vm:run delete "$vm_name" >/dev/null 2>&1 || true
		fi
		rm -rf "$tart_vm_dir" 2>/dev/null || true

		: "[tartConfig][INFO] factory reset cleanup completed for vm=$vm_name"
	}

	tart:vm:root-disk:ensure() {
		local expected_root_bytes=0
		local observed_root_bytes=""
		local primary_source=""

		tart:vm:ensure "$vm_name" "$vm_disk_size_gib" "$vm_disk_format"
		tart:vm:run stop "$vm_name" >/dev/null 2>&1 || true

		if [ ! -f "$tart_vm_disk" ]; then
			: "[tartConfig][WARN] tart VM root disk missing after ensure; recreating VM to restore canonical empty root disk layout"
			tart:vm:recreate "$vm_name" "$vm_disk_size_gib" "$vm_disk_format"
			tart:vm:disks:ensure:blank
			tart:vm:run stop "$vm_name" >/dev/null 2>&1 || true
		fi

		if [ ! -d "$tart_vm_dir" ]; then
			: "[tartConfig][ERROR] tart VM directory missing after ensure/create: $tart_vm_dir"
			exit 1
		fi

		primary_source="$(
			tart:raw-image:path:from-manifest primary 2>/dev/null \
				|| { [[ -n "${raw_image_store_path:-}" && -f "${raw_image_store_path:-}" ]] && printf '%s\n' "$raw_image_store_path"; } \
				|| { [[ -n "${raw_image_source_path:-}" && -f "${raw_image_source_path:-}" ]] && printf '%s\n' "$raw_image_source_path"; } \
				|| { [[ -n "${raw_image_target_path:-}" && -f "${raw_image_target_path:-}" ]] && printf '%s\n' "$raw_image_target_path"; } \
				|| true
		)"
		if [[ -n "$primary_source" ]]; then
			if ! tart:image:size:matches-source "$primary_source" "$tart_vm_disk"; then
				tart:disk:image:materialize-from-source "$primary_source" "$tart_vm_disk" "root disk (primary image)"
			else
				: "[tartConfig][INFO] preserving existing EFI root disk content (size matches source): $tart_vm_disk"
			fi
			asif_output="$tart_vm_disk"
			chmod 0644 "$asif_output" 2>/dev/null || true
			if [[ "$(id -u)" -eq 0 ]] && [[ -n "$profile_group" ]] && [[ "$asif_output" == "${effective_home}/"* ]]; then
				chown "${profile_user}:${profile_group}" "$asif_output" 2>/dev/null || true
			fi
			if [ ! -e "$asif_output" ]; then
				: "[tartConfig][ERROR] root disk missing after manifest materialization: $asif_output"
				exit 1
			fi
			return 0
		fi

		expected_root_bytes=$((vm_disk_size_gib * 1000 * 1000 * 1000))
		observed_root_bytes="$(tart:image:virtual-size-bytes "$tart_vm_disk" 2>/dev/null || true)"
		if [[ ! "$observed_root_bytes" =~ ^[0-9]+$ ]]; then
			: "[tartConfig][WARN] unable to read root disk virtual size; recreating VM with canonical size (${vm_disk_size_gib}GiB)"
			tart:vm:recreate "$vm_name" "$vm_disk_size_gib" "$vm_disk_format"
			tart:vm:disks:ensure:blank
			tart:vm:run stop "$vm_name" >/dev/null 2>&1 || true
		elif ((observed_root_bytes < expected_root_bytes)); then
			TART_LOG_PREFIX="[tartConfig]"
			if ! tart:image:resize-if-smaller "$tart_vm_disk" "$vm_disk_size_gib" "root disk"; then
				: "[tartConfig][WARN] root disk resize failed; recreating VM with canonical size (${vm_disk_size_gib}GiB)"
				tart:vm:recreate "$vm_name" "$vm_disk_size_gib" "$vm_disk_format"
				tart:vm:disks:ensure:blank
				tart:vm:run stop "$vm_name" >/dev/null 2>&1 || true
			fi
		elif ((observed_root_bytes > expected_root_bytes)); then
			: "[tartConfig][INFO] root disk already larger than configured target; keeping existing size (observedBytes=$observed_root_bytes targetBytes=$expected_root_bytes)"
		fi

		asif_output="$tart_vm_disk"
		: "preserving existing root disk content at: $asif_output"

		chmod 0644 "$asif_output" 2>/dev/null || true
		if [[ "$(id -u)" -eq 0 ]] && [[ -n "$profile_group" ]] && [[ "$asif_output" == "${effective_home}/"* ]]; then
			chown "${profile_user}:${profile_group}" "$asif_output" 2>/dev/null || true
		fi

		if [ ! -e "$asif_output" ]; then
			: "[tartConfig][ERROR] root disk missing after VM ensure/recreate: $asif_output"
			exit 1
		fi
	}

	tart:vm:zfs:pool-size:validate() {
		local tank_disks=()
		local disk=""
		local expected_bytes=""
		local current_bytes=""

		for disk in "${tart_vm_data_disks[@]}"; do
			[[ "$(basename "$disk" .img)" =~ ^tank ]] || continue
			tank_disks+=("$disk")
		done

		for disk in "${tank_disks[@]}"; do
			if ! tart:root-disk:zfs:contains "$disk"; then
				return 0
			fi
		done

		for disk in "${tank_disks[@]}"; do
			current_bytes="$(tart:image:virtual-size-bytes "$disk" 2>/dev/null || true)"
			if [[ ! "$current_bytes" =~ ^[0-9]+$ ]]; then
				: "[tartConfig][ERROR] unable to resolve ZFS tank disk size for consistency check: $disk"
				exit 1
			fi

			if [[ -z "$expected_bytes" ]]; then
				expected_bytes="$current_bytes"
			elif [[ "$current_bytes" != "$expected_bytes" ]]; then
				: "[tartConfig][ERROR] ZFS tank disk sizes diverge (expected=${expected_bytes} got=${current_bytes} disk=${disk}); rematerialize from bringup manifest"
				exit 1
			fi
		done

		: "[tartConfig][INFO] ZFS tank disk size consistency validated (tank1/tank2/tank3 bytes=${expected_bytes})"
	}

	tart:vm:config:patch() {
		if [ -f "$tart_vm_config" ]; then
			VM_DISK_FORMAT="$vm_disk_format" \
				VM_DISPLAY_WIDTH="$vm_display_width" \
				VM_DISPLAY_HEIGHT="$vm_display_height" \
				VM_MAC_ADDRESS="$vm_mac_address" \
				yq -o=json -I=2 -i '.diskFormat = strenv(VM_DISK_FORMAT) |
                           .display = (.display // {}) |
                           .display.width = (strenv(VM_DISPLAY_WIDTH) | tonumber) |
                           .display.height = (strenv(VM_DISPLAY_HEIGHT) | tonumber) |
                           .macAddress = strenv(VM_MAC_ADDRESS)' "$tart_vm_config"
		fi
	}

	tart:vm:finalize() {
		chmod 0644 "$tart_vm_disk" 2>/dev/null || true
		if [[ "$(id -u)" -eq 0 ]] && [[ -n "$profile_group" ]] && [[ "$tart_vm_disk" == "${effective_home}/"* ]]; then
			chown "${profile_user}:${profile_group}" "$tart_vm_disk" 2>/dev/null || true
		fi

		tart:vm:run set "$vm_name" --cpu "$vm_cpu_count" --memory "$vm_memory_mib"
		tart:fs:path:relink "$tart_run_script_store" "$tart_vm_run_wrapper" "tart run wrapper link"
	}

	tart:config:resolve() {
		profile_user="${PROFILE_USER:-${profile_user_default:-}}"
		configured_home="${PROFILE_HOME:-${profile_home_default:-${HOME:-}}}"
		effective_host_name="${effective_host_name_default:-unknown}"

		if [[ -z "$profile_user" ]]; then
			: "[tartConfig][ERROR] profile_user is not set (PROFILE_USER or profile_user_default)"
			exit 1
		fi

		if [[ -z "$configured_home" ]]; then
			: "[tartConfig][ERROR] profile_home is not set (PROFILE_HOME or profile_home_default)"
			exit 1
		fi

		if id -u "$profile_user" >/dev/null 2>&1; then
			profile_group="$(id -gn "$profile_user" 2>/dev/null || true)"
		fi

		if [[ -n "${NDH_GCROOT_USER:-}" ]] && id -u "${NDH_GCROOT_USER}" >/dev/null 2>&1; then
			gcroot_user="${NDH_GCROOT_USER}"
		elif [[ "$(id -u)" -eq 0 ]] && [[ -n "${SUDO_USER:-}" ]] && id -u "${SUDO_USER}" >/dev/null 2>&1; then
			gcroot_user="${SUDO_USER}"
		else
			gcroot_user="$(id -un)"
		fi

		if [[ -n "$gcroot_user" ]] && id -u "$gcroot_user" >/dev/null 2>&1; then
			gcroot_group="$(id -gn "$gcroot_user" 2>/dev/null || true)"
		fi

		if [[ -n "${tart_nix_cli_args_raw}" ]]; then
			: "NIX_CLI_ARGS is set but not consumed by activation: ${tart_nix_cli_args_raw}"
		fi

		if tart:bool:is-true "$tart_factory_reset_raw"; then
			factory_reset=1
		fi

		: "start $(date) host=${effective_host_name} user=${profile_user}"

		tart:runtime:home:resolve

		vm_name="${vm_name:-}"
		vm_disk_format="${vm_disk_format:-asif}"
		vm_disk_size_gib="${VM_DISK_SIZE_GIB:-${vm_disk_size_gib:-}}"
		vm_cpu_count="${vm_cpu_count:-}"
		vm_memory_mib="${vm_memory_mib:-}"
		vm_display_width="${vm_display_width:-}"
		vm_display_height="${vm_display_height:-}"
		vm_mac_address="${vm_mac_address:-}"
		# NOTE: this is only for additional VM-local data disks (disk2/disk3/recover),
		# not for root/bringup image sizing.
		data_disk_size_gib="${VM_DATA_DISK_SIZE_GIB:-${data_disk_size_gib:-}}"
		tart_binary_hint="${tart_bin:-}"
		diskutil_bin="${diskutil_bin:-/usr/sbin/diskutil}"
		raw_image_manifest_path="${NDH_IMAGE_MANIFEST_OVERRIDE:-${raw_image_manifest_path_default:-}}"
		raw_image_store_path="${NDH_IMAGE_STORE_OVERRIDE:-${raw_image_store_path_default:-}}"
		raw_image_source_path="${raw_image_source_path_default:-}"
		raw_image_target_path="${raw_image_target_path_default:-}"
		tart_run_script_store="${tart_run_script_store:-@tartRunScript@}"

		tart:raw-image:manifest:auto-resolve

		if [[ -z "$vm_name" || -z "$vm_disk_size_gib" || -z "$vm_cpu_count" || -z "$vm_memory_mib" || -z "$data_disk_size_gib" || -z "$tart_run_script_store" ]]; then
			: "[tartConfig][ERROR] activation config missing required fields (vm_name/vm_disk_size_gib/vm_cpu_count/vm_memory_mib/data_disk_size_gib/tart_run_script_store)"
			exit 1
		fi

		tart:runtime:path:setup
		tart:runtime:tooling:validate

		tart_vm_dir="${effective_home}/.tart/vms/${vm_name}"
		tart_vm_disk="${tart_vm_dir}/disk.img"
		tart_vm_config="${tart_vm_dir}/config.json"
		tart_vm_run_wrapper="${effective_home}/.tart/vms/${vm_name}.sh"
		tart:disks:from-manifest:init
	}

	# ---- execution area (no function definitions below) ----
	tart:state:init
	tart:manifest:load
	tart:config:resolve
	tart:raw-images:gcroot:materialize

	tart:vm:factory-reset:apply
	tart:vm:root-disk:ensure
	tart:vm:data-disks:size:enforce
	tart:vm:zfs:pool-size:validate
	tart:vm:config:patch
	tart:vm:finalize

	: "tart VM materialized vm=$vm_name diskFormat=$vm_disk_format mac=$vm_mac_address cpu=$vm_cpu_count memoryMiB=$vm_memory_mib"
	: "tart run wrapper installed: $tart_vm_run_wrapper"

	: "done rootDisk=$tart_vm_disk"
	: "end $(date)"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	ndh::logger:command:run "darwin.activationScripts.postActivation.tart-config" main "$@"
fi
