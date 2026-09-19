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

tart:image:info:json() {
	# The single door to `diskutil image info`, as JSON.
	#
	# Reading the plist as XML forces the caller to align interleaved <key> and
	# value elements by index, and that alignment collapses when a dict holds a
	# single entry: yq renders it as a map rather than a sequence, the
	# expression errors, and the caller sees an EMPTY result — indistinguishable
	# from "this image declares no partitions", i.e. from "this disk is a blank
	# placeholder, erase it".  Going through plutil lets fields be addressed by
	# name, so one partition reads like three.
	local image_path="$1"
	local json=""

	if [[ ! -f "$image_path" ]]; then
		return 1
	fi

	if [[ -z "${diskutil_bin:-}" ]]; then
		diskutil_bin="/usr/sbin/diskutil"
	fi

	json="$(
		"$diskutil_bin" image info --plist "$image_path" 2>/dev/null |
			plutil -convert json -o - - 2>/dev/null || true
	)"

	# Every successful answer carries "Image Format".  Its absence means the
	# introspection itself failed — the image is held open by a running VM
	# ("Resource temporarily unavailable"), or a tool is missing from PATH — and
	# that must never be reported as an image without partitions.
	if [[ -z "$json" ]] || ! printf '%s' "$json" | yq -p=json -e '.["Image Format"]' >/dev/null 2>&1; then
		return 1
	fi

	printf '%s\n' "$json"
}

tart:image:format() {
	tart:image:info:json "$1" | yq -p=json -r '.["Image Format"]'
}

tart:image:virtual-size-bytes() {
	local total_bytes=""

	total_bytes="$(tart:image:info:json "$1" | yq -p=json -r '.["Size Info"]["Total Bytes"]' || true)"

	if [[ ! "$total_bytes" =~ ^[0-9]+$ ]]; then
		return 1
	fi

	printf '%s\n' "$total_bytes"
}

tart:image:partition:hint:present() {
	# tart:image:partition:hint:present <image> <hint_substring>
	#
	# 0 = some partition carries the hint · 1 = none does · 2 = not
	# introspectable.  The third outcome is not pedantry: callers ERASE disks on
	# a negative answer, so "I could not look" must never collapse into "there
	# is nothing there".
	local image_path="$1"
	local wanted="${2,,}"
	local json=""
	local hints=""
	local hint=""

	json="$(tart:image:info:json "$image_path")" || return 2
	# Bracketed key access throughout: yq's lexer rejects `."Image Format"` but
	# accepts `.["Image Format"]`, so one form works for every key.
	hints="$(printf '%s\n' "$json" | yq -p=json -r '.Partitions[]["content-hint"]' 2>/dev/null || true)"

	while IFS= read -r hint; do
		hint="${hint,,}"
		if [[ -n "$hint" && "$hint" == *"$wanted"* ]]; then
			return 0
		fi
	done <<< "$hints"

	return 1
}

tart:image:zfs:contains() {
	# A ZFS member disk reports a "ZFS" (or Solaris) partition hint; a blank
	# placeholder created with `--fs None` reports one partition with an EMPTY
	# hint.  The two are unambiguous, which is what lets the caller erase one
	# and preserve the other.  Propagates the three-valued contract.
	local image_path="$1"
	local status=0

	tart:image:partition:hint:present "$image_path" zfs || status=$?
	if ((status != 1)); then
		return "$status"
	fi

	tart:image:partition:hint:present "$image_path" solaris
}

tart:image:efi:contains() {
	# Positive content test for "this disk was materialized from a boot image",
	# and the reason it replaced a virtual-size comparison against the source:
	# size is not a marker.  It matched only by coincidence (source and target
	# both 600 MiB), and any change to the boot image's size would have flipped
	# the gate to "re-materialize", silently wiping the node's ESP and its
	# NixOS generations.
	tart:image:partition:hint:present "$1" efi
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

	return 0
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

	return 0
}

main() {
	set -euo pipefail

	# Manifest resolution order (most explicit first):
	#   1. --config FILE on the CLI
	#   2. NDH_TART_VM_CONFIG env var
	#   3. The bundle's own embedded path (@manifestPath@); empty in the
	#      generic nerd-tart deploy bundle, host-specific in the per-host
	#      materializer/deploy bundles.
	# When the embedded path is empty AND no override is provided, we abort:
	# the operator must opt in by selecting which VM identity to activate.
	local cli_config_path=""
	local positional_args=()
	while (($# > 0)); do
		case "$1" in
			--config)
				if (($# < 2)); then
					echo "[tartConfig][ERROR] --config requires an argument" >&2
					exit 2
				fi
				cli_config_path="$2"
				shift 2
				;;
			--config=*)
				cli_config_path="${1#--config=}"
				shift
				;;
			*)
				positional_args+=("$1")
				shift
				;;
		esac
	done
	if ((${#positional_args[@]} > 0)); then
		set -- "${positional_args[@]}"
	else
		set --
	fi

	local manifest_path=""
	if [[ -n "$cli_config_path" ]]; then
		manifest_path="$cli_config_path"
	elif [[ -n "${NDH_TART_VM_CONFIG:-}" ]]; then
		manifest_path="$NDH_TART_VM_CONFIG"
	else
		manifest_path="@manifestPath@"
	fi

	if [[ -z "$manifest_path" ]]; then
		: "[tartConfig][ERROR] no run manifest selected; pass --config FILE or set NDH_TART_VM_CONFIG"
		exit 1
	fi

	# Propagate to run.sh (invoked via the per-VM wrapper symlink) so it
	# reads the same manifest without repeating the resolution logic.
	export NDH_TART_VM_CONFIG="$manifest_path"

	local tart_nix_cli_args_raw="${NIX_CLI_ARGS:--L -v -v}"
	local profile_user=""
	local factory_reset="${VM_FACTORY_RESET:-false}"
	local configured_home=""
	local effective_host_name=""

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
		tart_vm_prebuilt_disks=()

		while IFS=$'\t' read -r image_name image_role; do
			[[ -n "$image_name" ]] || continue
			[[ "$image_role" != "primary" ]] || continue
			# Prebuilt images (e.g. the read-only EROFS store lower) are finished
			# filesystems, not pool members: they are copied verbatim and never
			# blank-created, grown, or probed for ZFS partition labels.
			if [[ "$image_role" == "prebuilt" ]]; then
				tart_vm_prebuilt_disks+=("${tart_vm_dir}/${image_name}.img")
				continue
			fi
			tart_vm_data_disks+=("${tart_vm_dir}/${image_name}.img")
		done < <(tart:manifest:images:enumerate)

		if [[ ${#tart_vm_data_disks[@]} -eq 0 ]]; then
			# Fatal on purpose: the old hardcoded layout predates the prebuilt
			# store disk and omits it, so materializing from a guessed set
			# yields a VM that hangs in the initrd on a missing
			# /dev/disk/by-label/nix-store.
			: "[tartConfig][ERROR] no disks resolved from bringup manifest: ${raw_image_manifest_path:-<unresolved>}"
			: "[tartConfig][ERROR] refusing to materialize a guessed disk set; check that the gcroot resolves to the current bundle"
			exit 1
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
			: "${label}: $dst -> $(readlink "$dst" || echo '<not-a-symlink>')"
			return 0
		fi

		: "[tartConfig][ERROR] ${label} destination is not a symlink after update: $dst"
		return 1
	}

	tart:fs:dir:ensure() {
		local dir="$1"
		local mode="${2:-0755}"
		install -d -m "$mode" "$dir"
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

	tart:runtime:user:resolve() {
		# Counterpart of tart:runtime:home:resolve, for the account name.
		# profile_user comes from the Nix config (profile.user.name), which may
		# legitimately name an account absent from the machine actually running
		# the materializer. The home already self-heals that way; without the
		# same treatment here the two disagree: disk images land in the real
		# home while the gcroot goes under the configured account, and run.sh
		# then reads a manifest that does not describe the VM it is starting —
		# producing a VM whose store disk is never attached.
		runtime_user="${runtime_user:-$(id -un)}"

		if id -u "$profile_user" >/dev/null 2>&1; then
			return 0
		fi

		: "[tartConfig][WARN] configured profile user does not exist on this host: ${profile_user}; using runtime user: ${runtime_user}"
		profile_user="$runtime_user"
	}

	tart:runtime:gcroot:realign() {
		# Keep the gcroot next to the files it keeps alive: its path is baked
		# from the configured account, so it has to follow the effective one.
		[[ -n "${configured_user:-}" && "$configured_user" != "$profile_user" ]] || return 0
		[[ -n "${raw_image_target_path:-}" ]] || return 0

		local realigned="${raw_image_target_path//\/per-user\/${configured_user}\//\/per-user\/${profile_user}\/}"
		[[ "$realigned" != "$raw_image_target_path" ]] || return 0

		: "[tartConfig][WARN] realigning gcroot on the effective user: ${raw_image_target_path} -> ${realigned}"
		raw_image_target_path="$realigned"
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

		tart:fs:dir:ensure "$(dirname "$target_path")" 0755

		# Use the store path embedded at build time — avoids any BASH_SOURCE[0] / symlink
		# resolution issues when the script is invoked via a wrapper or the gcroot itself.
		local bundle_dir="@tartActivationBundlePlaceholder@"
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

		# Primary: follow the gcroot bundle — use the store path embedded at build time.
		local bundle_dir="@tartActivationBundlePlaceholder@"
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
	}

	tart:vm:run() {
		"$tart_bin" "$@"
	}

	tart:vm:exists() {
		# Only a formal "does not exist" authorises the caller to create the VM,
		# because `tart create` recreates the VM directory and takes the data
		# disks with it.  Anything we cannot read that way counts as existing.
		#
		# `tart get` answers about ONE VM and encodes the outcome in its exit
		# code — 0 registered · 2 "the specified VM does not exist" · 1 for a
		# running VM, which holds its disk images open so diskutil answers
		# "Resource temporarily unavailable".  That 1 is positive evidence of
		# existence, not an unknown: to reach the disk at all tart had to resolve
		# the VM, and it names the resolved path in the error.  Verified on both
		# hosts.
		#
		# It replaces a `tart list` scan that was wrong twice over: it read the
		# table's FIRST column as the VM name, but that column is Source, so the
		# predicate compared "local" to the name and could never answer yes; and
		# tart 2.36 fails the WHOLE listing when any single VM is running (10/10
		# on the host where one runs permanently, while 2.30 tolerated it). Both
		# faults surfaced as "not registered", the caller answered with `tart
		# create`, and a materialization erased live ZFS pools.
		local vm="$1"
		local status=0

		tart:vm:run get --format=json "$vm" >/dev/null 2>&1 || status=$?

		((status == 2)) && return 1
		return 0
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

		# Only create blank data disks if the VM directory had no pre-existing disk
		# images (e.g. from a previous activation that materialized bringup images
		# before tart create was called). Preserving existing disks here avoids
		# wiping freshly-materialized bringup ZFS images.
		local any_existing=0
		local _d
		for _d in "${tart_vm_data_disks[@]}"; do
			[[ -f "$_d" ]] && { any_existing=1; break; }
		done
		if ((any_existing == 0)); then
			tart:vm:disks:ensure:blank
		else
			: "[tartConfig][INFO] tart VM registered; preserving existing data disk images"
		fi
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

		# Last line of defence, behind tart:vm:exists.  Blanking is decided
		# elsewhere; this only refuses to carry it out on a disk that still holds
		# a pool — or whose partition table cannot be read, which is the same
		# "I could not look" that already cost us one node's pools.
		if [[ -f "$disk" ]]; then
			local zfs_probe=0
			tart:image:zfs:contains "$disk" || zfs_probe=$?
			if ((zfs_probe != 1)); then
				: "[tartConfig][ERROR] refusing to blank a data disk that holds ZFS data, or whose partition table is unreadable (probe=${zfs_probe}): $disk"
				exit 1
			fi
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
		local current_bytes=""
		local expected_bytes=0
		local disk_format=""
		local zfs_probe=0

		for disk in "${tart_vm_data_disks[@]}"; do
			manifest_image_name="$(basename "$disk" .img)"
			manifest_source=""

			if [[ -n "$manifest_image_name" ]]; then
				manifest_source="$(tart:raw-image:path:from-manifest "$manifest_image_name" 2>/dev/null || true)"
			fi

			if [[ -f "$disk" ]]; then
				# Detect blank placeholder disks: ASIF format means the disk was
				# created by tart:vm:disks:ensure:blank and has no real data.
				# EXCEPTION: after initial bringup materialization, the disk is ASIF
				# format but contains live ZFS data — detect this from the partition
				# table and preserve it unconditionally.
				disk_format="$(tart:image:format "$disk" 2>/dev/null || true)"
				if [[ "$disk_format" == "ASIF" && -n "$manifest_source" ]]; then
					zfs_probe=0
					tart:image:zfs:contains "$disk" || zfs_probe=$?
					if ((zfs_probe == 0)); then
						: "[tartConfig][INFO] ${manifest_image_name} ASIF data disk has live ZFS data; preserving: $disk"
						continue
					fi
					if ((zfs_probe == 2)); then
						# This is the one branch that destroys data, so it only ever
						# runs on a POSITIVE answer.  An unreadable partition table
						# used to read as "no ZFS here" and took the disk with it.
						: "[tartConfig][ERROR] ${manifest_image_name} data disk partition table is unreadable; refusing to replace a disk that may hold a live pool: $disk"
						exit 1
					fi
					: "[tartConfig][INFO] ${manifest_image_name} data disk is blank ASIF placeholder; re-materializing from source: $manifest_source"
					rm -f "$disk"
				else
					current_bytes="$(tart:image:virtual-size-bytes "$disk" 2>/dev/null || true)"
					expected_bytes=$(( data_disk_size_gib * 1000 * 1000 * 1000 ))
					if [[ "$current_bytes" =~ ^[0-9]+$ ]] && (( current_bytes < expected_bytes )); then
						: "[tartConfig][WARN] ${manifest_image_name} data disk is smaller than vmDataDiskSizeGiB=${data_disk_size_gib} (currentBytes=${current_bytes} expectedBytes=${expected_bytes}); re-materialize manually to resize"
					else
						: "[tartConfig][INFO] preserving existing ${manifest_image_name} data disk: $disk"
					fi
					continue
				fi
			fi

			# Disk is missing — materialize from source image or create blank.
			if [[ -n "$manifest_source" ]]; then
				: "[tartConfig][INFO] ${manifest_image_name} data disk missing; materializing from source: $manifest_source"
				tart:disk:image:materialize-from-source "$manifest_source" "$disk" "${manifest_image_name} data disk"
				# Grow to the configured size immediately after initial materialization —
				# the bringup image is baked at build-time size which may be smaller
				# than the desired runtime vmDataDiskSizeGiB.
				TART_LOG_PREFIX="[tartConfig]"
				tart:image:resize-if-smaller "$disk" "$data_disk_size_gib" "${manifest_image_name} data disk" || true
			else
				: "[tartConfig][WARN] ${manifest_image_name} data disk missing; creating blank ASIF (${data_disk_size_gib}GiB): $disk"
				tart:vm:data-disk:create-asif "$disk" "$data_disk_size_gib"
			fi
		done
	}

	tart:vm:prebuilt-disks:ensure() {
		# Prebuilt images are finished read-only filesystems (the EROFS store
		# lower), so unlike data disks they are copied verbatim: no blank
		# creation, and deliberately no resize — growing a read-only filesystem
		# only wastes host space, the guest finds it by label either way.
		local disk="" manifest_image_name="" manifest_source="" marker=""

		# Safe to skip quietly: by this point the manifest is known to have
		# resolved (tart:disks:from-manifest:init aborts otherwise), so an empty
		# list means the bundle genuinely declares no prebuilt image — an
		# older-style image whose system config does not expect one. It is the
		# unresolved-manifest case that must never reach here silently.
		# The guard is also needed because `set -u` makes expanding an empty
		# array fatal on some bash builds.
		if [[ ${#tart_vm_prebuilt_disks[@]} -eq 0 ]]; then
			return 0
		fi

		for disk in "${tart_vm_prebuilt_disks[@]}"; do
			manifest_image_name="$(basename "$disk" .img)"
			manifest_source="$(tart:raw-image:path:from-manifest "$manifest_image_name" 2>/dev/null || true)"

			if [[ -z "$manifest_source" ]]; then
				: "[tartConfig][ERROR] prebuilt image has no manifest source: $manifest_image_name"
				exit 1
			fi

			# The source is a store path, so its identity IS its content — record
			# it and skip the work when unchanged.  Content comparison cannot do
			# this job here: the target is ASIF-converted, so it never compares
			# equal to the raw source and would be rebuilt on every activation.
			marker="${disk}.source"
			if [[ -f "$disk" && -f "$marker" ]] && [[ "$(cat "$marker")" == "$manifest_source" ]]; then
				: "[tartConfig][INFO] ${manifest_image_name} prebuilt image already matches source; keeping: $disk"
				continue
			fi

			: "[tartConfig][INFO] ${manifest_image_name} prebuilt image materializing from source: $manifest_source"
			tart:disk:image:materialize-from-source "$manifest_source" "$disk" "${manifest_image_name} prebuilt image"
			printf '%s\n' "$manifest_source" > "$marker"
		done
	}

	tart:vm:factory-reset:apply() {
		if ! $factory_reset; then
			return 0
		fi

		: "[tartConfig][WARN] factory reset requested"
		: "[tartConfig][WARN] removing existing Tart root/data images before recreation"

		tart:vm:run stop "$vm_name" >/dev/null 2>&1 || true
		if tart:vm:exists "$vm_name"; then
			: "[tartConfig][INFO] deleting existing VM definition to force root disk recreation via tart create"
			tart:vm:run delete "$vm_name" >/dev/null 2>&1 || true
		fi
		rm -rf "$tart_vm_dir" 2>/dev/null || true

		: "[tartConfig][INFO] factory reset cleanup completed for vm=$vm_name"
	}

	tart:vm:disks:released:await() {
		# `tart stop` returns before Virtualization.framework has closed the disk
		# images, and every gate below reads a partition table to decide whether
		# to preserve or erase.  A still-held image reports "unreadable", which
		# is fatal by design now — so wait for the release instead of racing it.
		local waited=0
		local limit="${TART_DISK_RELEASE_TIMEOUT_SECONDS:-30}"

		# Nothing to wait for on a VM whose root disk does not exist yet.
		[[ -f "$tart_vm_disk" ]] || return 0

		while ((waited < limit)); do
			if tart:image:info:json "$tart_vm_disk" >/dev/null 2>&1; then
				return 0
			fi
			sleep 1
			waited=$((waited + 1))
		done

		: "[tartConfig][ERROR] VM disk images still held ${limit}s after stop; refusing to inspect or replace them: $tart_vm_disk"
		exit 1
	}

	tart:vm:root-disk:ensure() {
		local expected_root_bytes=0
		local observed_root_bytes=""
		local primary_source=""
		local root_marker=""
		local root_action=""
		local efi_probe=0

		tart:vm:ensure "$vm_name" "$vm_boot_disk_size_gib" "$vm_disk_format"
		tart:vm:run stop "$vm_name" >/dev/null 2>&1 || true

		if [ ! -f "$tart_vm_disk" ]; then
			: "[tartConfig][WARN] tart VM root disk missing after ensure; recreating VM to restore canonical empty root disk layout"
			tart:vm:recreate "$vm_name" "$vm_boot_disk_size_gib" "$vm_disk_format"
			tart:vm:disks:ensure:blank
			tart:vm:run stop "$vm_name" >/dev/null 2>&1 || true
		fi

		if [ ! -d "$tart_vm_dir" ]; then
			: "[tartConfig][ERROR] tart VM directory missing after ensure/create: $tart_vm_dir"
			exit 1
		fi

		tart:vm:disks:released:await

		primary_source="$(
			tart:raw-image:path:from-manifest primary 2>/dev/null \
				|| { [[ -n "${raw_image_store_path:-}" && -f "${raw_image_store_path:-}" ]] && printf '%s\n' "$raw_image_store_path"; } \
				|| { [[ -n "${raw_image_source_path:-}" && -f "${raw_image_source_path:-}" ]] && printf '%s\n' "$raw_image_source_path"; } \
				|| { [[ -n "${raw_image_target_path:-}" && -f "${raw_image_target_path:-}" ]] && printf '%s\n' "$raw_image_target_path"; } \
				|| true
		)"
		if [[ -n "$primary_source" ]]; then
			root_marker="${tart_vm_disk}.source"
			root_action="materialize"

			if $factory_reset; then
				: "[tartConfig][INFO] factory reset requested; root disk will be materialized from source: $primary_source"
			elif [[ -f "$root_marker" ]] && [[ "$(cat "$root_marker")" == "$primary_source" ]]; then
				# Same marker discipline as prebuilt images: the source is a store
				# path, so its identity IS its content.  Content comparison cannot
				# stand in — the target is ASIF-converted and never compares equal.
				root_action="preserve"
				: "[tartConfig][INFO] root disk already materialized from this source; preserving: $tart_vm_disk"
			else
				efi_probe=0
				tart:image:efi:contains "$tart_vm_disk" || efi_probe=$?
				case "$efi_probe" in
				0)
					# The root disk is MUTABLE: it carries the node's ESP and the
					# NixOS generations installed since bringup.  So a source that
					# no longer matches is reported, not acted on — replacing it is
					# destructive and stays an explicit operator act.  A prebuilt
					# image is the opposite: read-only and content-addressed, hence
					# swapped freely.
					root_action="preserve"
					: "[tartConfig][WARN] root disk holds materialized content from another source; preserving it (set VM_FACTORY_RESET=true to replace): $tart_vm_disk"
					;;
				2)
					: "[tartConfig][ERROR] root disk partition table is unreadable; refusing to decide whether to replace it: $tart_vm_disk"
					exit 1
					;;
				esac
			fi

			if [[ "$root_action" == "materialize" ]]; then
				tart:disk:image:materialize-from-source "$primary_source" "$tart_vm_disk" "root disk (primary image)"
				printf '%s\n' "$primary_source" > "$root_marker"
			fi

			asif_output="$tart_vm_disk"
			chmod 0644 "$asif_output" 2>/dev/null || true
			if [ ! -e "$asif_output" ]; then
				: "[tartConfig][ERROR] root disk missing after manifest materialization: $asif_output"
				exit 1
			fi
			return 0
		fi

		expected_root_bytes=$((vm_boot_disk_size_gib * 1000 * 1000 * 1000))
		observed_root_bytes="$(tart:image:virtual-size-bytes "$tart_vm_disk" 2>/dev/null || true)"
		if [[ ! "$observed_root_bytes" =~ ^[0-9]+$ ]]; then
			: "[tartConfig][WARN] unable to read root disk virtual size; recreating VM with canonical size (${vm_boot_disk_size_gib}GiB)"
			tart:vm:recreate "$vm_name" "$vm_boot_disk_size_gib" "$vm_disk_format"
			tart:vm:disks:ensure:blank
			tart:vm:run stop "$vm_name" >/dev/null 2>&1 || true
		elif ((observed_root_bytes < expected_root_bytes)); then
			TART_LOG_PREFIX="[tartConfig]"
			if ! tart:image:resize-if-smaller "$tart_vm_disk" "$vm_boot_disk_size_gib" "root disk"; then
				: "[tartConfig][WARN] root disk resize failed; recreating VM with canonical size (${vm_boot_disk_size_gib}GiB)"
				tart:vm:recreate "$vm_name" "$vm_boot_disk_size_gib" "$vm_disk_format"
				tart:vm:disks:ensure:blank
				tart:vm:run stop "$vm_name" >/dev/null 2>&1 || true
			fi
		elif ((observed_root_bytes > expected_root_bytes)); then
			: "[tartConfig][INFO] root disk already larger than configured target; keeping existing size (observedBytes=$observed_root_bytes targetBytes=$expected_root_bytes)"
		fi

		asif_output="$tart_vm_disk"
		: "preserving existing root disk content at: $asif_output"

		chmod 0644 "$asif_output" 2>/dev/null || true

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

		# The check only means something once every tank disk is a live pool
		# member; before that (blank placeholders, or a table we cannot read) the
		# sizes are expected to differ and comparing them would be noise.
		for disk in "${tank_disks[@]}"; do
			if ! tart:image:zfs:contains "$disk"; then
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
			# memorySizeMin is set to memorySizeMax so Apple VZ gives the full
			# allocation immediately rather than ballooning up from the 4 GiB default.
			local vm_memory_bytes=$(( vm_memory_mib * 1024 * 1024 ))
			VM_DISK_FORMAT="$vm_disk_format" \
				VM_DISPLAY_WIDTH="$vm_display_width" \
				VM_DISPLAY_HEIGHT="$vm_display_height" \
				VM_MAC_ADDRESS="$vm_mac_address" \
				VM_MEMORY_BYTES="$vm_memory_bytes" \
				yq -o=json -I=2 -i '.diskFormat = strenv(VM_DISK_FORMAT) |
                           .display = (.display // {}) |
                           .display.width = (strenv(VM_DISPLAY_WIDTH) | tonumber) |
                           .display.height = (strenv(VM_DISPLAY_HEIGHT) | tonumber) |
                           .macAddress = strenv(VM_MAC_ADDRESS) |
                           .memorySizeMin = (strenv(VM_MEMORY_BYTES) | tonumber)' "$tart_vm_config"
		fi
	}

	tart:vm:finalize() {
		chmod 0644 "$tart_vm_disk" 2>/dev/null || true

		tart:vm:run set "$vm_name" --cpu "$vm_cpu_count" --memory "$vm_memory_mib"
		tart:fs:path:relink "$tart_run_script_store" "$tart_vm_run_wrapper" "tart run wrapper link"
	}

	tart:config:resolve() {
		profile_user="${PROFILE_USER:-${profile_user_default:-}}"
		# Kept so the gcroot path, baked from this value, can be realigned once
		# the effective user is known.
		configured_user="$profile_user"
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

		if [[ -n "${tart_nix_cli_args_raw}" ]]; then
			: "NIX_CLI_ARGS is set but not consumed by activation: ${tart_nix_cli_args_raw}"
		fi

		: "start $(date) host=${effective_host_name} user=${profile_user}"

		tart:runtime:home:resolve
		tart:runtime:user:resolve

		vm_name="${vm_name:-}"
		vm_disk_format="${vm_disk_format:-asif}"
		vm_boot_disk_size_gib="${VM_BOOT_DISK_SIZE_GIB:-${vm_boot_disk_size_gib:-}}"
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

		# Must precede the manifest auto-resolve below: that reads the gcroot.
		tart:runtime:gcroot:realign

		tart:raw-image:manifest:auto-resolve

		if [[ -z "$vm_name" || -z "$vm_boot_disk_size_gib" || -z "$vm_cpu_count" || -z "$vm_memory_mib" || -z "$data_disk_size_gib" || -z "$tart_run_script_store" ]]; then
			: "[tartConfig][ERROR] activation config missing required fields (vm_name/vm_boot_disk_size_gib/vm_cpu_count/vm_memory_mib/data_disk_size_gib/tart_run_script_store)"
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
	tart:manifest:load
	tart:config:resolve

	# If running as root but the target profile is a regular user, re-exec the
	# entire script as that user. This ensures tart VM registry lookups and
	# creations happen under the correct user's ~/.tart, and all file operations
	# (disk images, gcroots, serial dirs) are naturally owned by profile_user
	# without per-operation chown/sudo wrappers.
	#
	# Before re-execing, ensure the gcroot directory exists and is owned by the
	# profile_user — this requires root and must happen here while we still have it.
	if [[ "$(id -u)" -eq 0 && -n "$profile_user" && "$profile_user" != "root" ]]; then
		local _gcroot_dir="/nix/var/nix/gcroots/per-user/${profile_user}"
		local _gcroot_group
		_gcroot_group="$(id -gn "$profile_user" 2>/dev/null || true)"
		install -d -m 0755 -o "$profile_user" -g "$_gcroot_group" "$_gcroot_dir"
		: "[tartConfig][INFO] activation running as root; re-execing as ${profile_user}"
		exec sudo -u "$profile_user" \
			HOME="$effective_home" \
			PROFILE_USER="$profile_user" \
			PROFILE_HOME="$effective_home" \
			-- "$0" "$@"
	fi

	tart:raw-images:gcroot:materialize

	tart:vm:factory-reset:apply
	tart:vm:root-disk:ensure
	tart:vm:data-disks:size:enforce
	tart:vm:prebuilt-disks:ensure
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
