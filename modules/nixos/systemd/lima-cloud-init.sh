#!/usr/bin/env bash
set -xe -o pipefail

# lima-cloud-init wrapper script extracted from Nix module (@codebase)
# Uses runtime PATH from systemd unit or wrapper runtimeInputs.

LIMA_CIDATA_MNT="${LIMA_CIDATA_MNT:-/mnt/lima-cidata}"
LIMA_CIDATA_DEV="${LIMA_CIDATA_DEV:-/dev/disk/by-label/cidata}"
PROFILE_USER_NAME="@profileUserName@"
LINUX_BUILDER_PUBLIC_KEY="@linuxBuilderPublicKey@"
COMMITTED_TRUSTED_CA_PUBLIC_KEY="@committedTrustedCaPublicKey@"

exec 1> >(tee -a "${LIMA_CLOUD_INIT_OUTPUT_LOG:-/var/log/lima-cloud-init-output.log}") \
     2> >(tee -a "${LIMA_CLOUD_INIT_LOG:-/var/log/lima-cloud-init.log}")

if [[ ! -r  "${LIMA_CIDATA_MNT}/lima.env" ]]; then
  echo "[lima-cloud-init] no lima.env present at ${LIMA_CIDATA_MNT}" >&2
  exit 2
fi

# Overlay write layer for modifications
mkdir -p "${LIMA_CIDATA_MNT}-upper" "${LIMA_CIDATA_MNT}-work"
mount -t overlay overlay \
  -o "lowerdir=${LIMA_CIDATA_MNT},upperdir=${LIMA_CIDATA_MNT}-upper,workdir=${LIMA_CIDATA_MNT}-work" \
  "${LIMA_CIDATA_MNT}"
# Keep overlay mounted so edits (e.g., param.env) persist for the lifetime of the system.
# Do not remove upper/work; leaving them ensures host reads modified files via /mnt/lima-cidata later.

# Ensure that Lima's param.env enforces PATH with /run/wrappers/bin first.
# The host SSH command exports param.env into the session, which can override sshd SetEnv.
PARAM_ENV_FILE="${LIMA_CIDATA_MNT}/param.env"
if [[ -f "${PARAM_ENV_FILE}" ]]; then
  if grep -qE '^PATH=' "${PARAM_ENV_FILE}"; then
    # Normalize PATH: drop all existing /run/wrappers/bin entries, then prefix once
    awk -v RS='\n' -v ORS='\n' '
      BEGIN { changed=0 }
      /^PATH=/ {
        val = substr($0, 6)
        n = split(val, parts, ":")
        out = "/run/wrappers/bin"; seen_wrappers=1
        for (i=1; i<=n; i++) {
          p = parts[i]
          if (p == "" || p == "/run/wrappers/bin") continue
          # avoid consecutive duplicates while rebuilding
          if (index(":" out ":", ":" p ":")==0) out = out ":" p
        }
        print "PATH=" out
        next
      }
      { print }
    ' "${PARAM_ENV_FILE}" > "${PARAM_ENV_FILE}.tmp" && mv "${PARAM_ENV_FILE}.tmp" "${PARAM_ENV_FILE}"
  else
    printf '%s\n' 'PATH=/run/wrappers/bin:/run/current-system/sw/bin:/nix/var/profiles/default/bin' >> "${PARAM_ENV_FILE}"
  fi
fi

# Force plain mode and normalise props; add derived helper variables
# These become available to later shell via source <( yq ... )
# shellcheck disable=SC1090,SC1091
yq --input-format=props --output-format=props --from-file <( cat <<'EoE'
  .LIMA_CIDATA_USER = .LIMA_CIDATA_USER // "limauser"       |
  .LIMA_CIDATA_UID  = .LIMA_CIDATA_UID  // 1000             |
  .LIMA_CIDATA_GID  = .LIMA_CIDATA_GID  // .LIMA_CIDATA_UID
EoE
) "${LIMA_CIDATA_MNT}/lima.env" |
  sed 's/ = /=/' > /tmp/lima.env.$$ &&
  mv /tmp/lima.env.$$ "${LIMA_CIDATA_MNT}/lima.env"

# shellcheck disable=SC1090,SC1091
source <( yq --input-format=props --output-format=shell "${LIMA_CIDATA_MNT}/lima.env" )

# Canonicalize guest home to Linux path.
# IMPORTANT: the host-provided home path from cidata must NOT become the VM account home.
# Any non-canonical value (e.g. /Users/<user>) is treated as optional compatibility alias only.
CANONICAL_HOME="/home/${LIMA_CIDATA_USER}"
CONFIGURED_HOME="${LIMA_CIDATA_HOME:-${CANONICAL_HOME}}"

if id -u "${LIMA_CIDATA_USER}" &>/dev/null; then
  EXISTING_UID=$(id -u "${LIMA_CIDATA_USER}")
  if [[ "${EXISTING_UID}" != "${LIMA_CIDATA_UID}" ]]; then
    echo "[lima-cloud-init] WARNING: existing UID ${EXISTING_UID} != requested ${LIMA_CIDATA_UID}" >&2
    LIMA_CIDATA_UID=${EXISTING_UID}
	LIMA_CIDATA_GID=$(id -g "${LIMA_CIDATA_USER}")
  fi
  usermod --home "${CANONICAL_HOME}" "${LIMA_CIDATA_USER}" || true
else
  useradd --home-dir "${CANONICAL_HOME}" --create-home --uid "${LIMA_CIDATA_UID}" "${LIMA_CIDATA_USER}"
fi

usermod -a -G wheel "${LIMA_CIDATA_USER}" || true
usermod -a -G users "${LIMA_CIDATA_USER}" || true

ln -fs /run/current-system/sw/bin/bash /bin/bash || true
ln -fs /run/wrappers/bin/sudo /bin/sudo
ln -fs /run/wrappers/bin/sudo /usr/bin/sudo || true

# Setup SSH
install -d -m 755 "/etc/ssh/nix_authorized_keys.d"

build_authorized_keys_for_user() {
  local target_user="$1"
  local auth_file="/etc/ssh/nix_authorized_keys.d/${target_user}"
  local tmp_keys
  local existing_tmp

  tmp_keys="$(mktemp)"
  existing_tmp="$(mktemp)"

  # 1) Preferred source: user-scoped keys from cidata user-data
  yq eval -r \
    ".users[]? | select((.name // \"\") == \"${target_user}\") | (.\"ssh-authorized-keys\" // .ssh_authorized_keys // [])[]?" \
    "${LIMA_CIDATA_MNT}/user-data" 2>/dev/null >> "${tmp_keys}" || true

  # 2) Compatibility source: unscoped keys if user-scoped extraction is empty
  if [[ ! -s "${tmp_keys}" ]]; then
    yq eval -r '.users[]? | (."ssh-authorized-keys" // .ssh_authorized_keys // [])[]?' \
      "${LIMA_CIDATA_MNT}/user-data" 2>/dev/null >> "${tmp_keys}" || true
  fi

  # 3) Bootstrap fallback: canonical linux-builder key from store-managed key model
  if [[ -n "${LINUX_BUILDER_PUBLIC_KEY}" ]]; then
    printf 'ssh-ed25519 %s %s\n' "${LINUX_BUILDER_PUBLIC_KEY}" "linux-builder@mammoth-skate" >> "${tmp_keys}"
  fi

  # 4) Preserve previous valid key file if fresh extraction is empty
  if [[ -s "${auth_file}" ]]; then
    cat "${auth_file}" > "${existing_tmp}"
  fi

  awk 'NF > 0 && $1 ~ /^ssh-/ { print }' "${tmp_keys}" | awk '!seen[$0]++' > "${tmp_keys}.clean"

  if [[ -s "${tmp_keys}.clean" ]]; then
    install -m 644 "${tmp_keys}.clean" "${auth_file}"
    chown "root:root" "${auth_file}"
    chmod 644 "${auth_file}"
    echo "[lima-cloud-init] installed authorized keys for ${target_user}: ${auth_file}"
  elif [[ -s "${existing_tmp}" ]]; then
    install -m 644 "${existing_tmp}" "${auth_file}"
    chown "root:root" "${auth_file}"
    chmod 644 "${auth_file}"
    echo "[lima-cloud-init][WARN] no fresh keys for ${target_user}; preserved existing ${auth_file}" >&2
  else
    echo "[lima-cloud-init][WARN] no authorized keys materialized for ${target_user}" >&2
  fi

  rm -f "${tmp_keys}" "${tmp_keys}.clean" "${existing_tmp}"
}

build_authorized_keys_for_user "${LIMA_CIDATA_USER}"
if [[ -n "${PROFILE_USER_NAME}" && "${PROFILE_USER_NAME}" != "${LIMA_CIDATA_USER}" ]]; then
  build_authorized_keys_for_user "${PROFILE_USER_NAME}"
fi

# Bootstrap certificate-auth trust fallback: keep trusted-user CA available
# even before runtime secret extraction populates /etc/ssh/keys.d.
install -d -m 755 "/etc/ssh/keys.d"
if [[ -n "${COMMITTED_TRUSTED_CA_PUBLIC_KEY}" ]]; then
  printf 'ssh-ed25519 %s %s\n' "${COMMITTED_TRUSTED_CA_PUBLIC_KEY}" "cert-authority@mammoth-skate" \
    > "/etc/ssh/keys.d/trusted-user-ca.pub"
  chown root:root "/etc/ssh/keys.d/trusted-user-ca.pub"
  chmod 644 "/etc/ssh/keys.d/trusted-user-ca.pub"
  echo "[lima-cloud-init] installed bootstrap trusted user CA: /etc/ssh/keys.d/trusted-user-ca.pub"
fi

# Optional compatibility alias for non-canonical home paths coming from cidata
# (e.g. /Users/<user>): reverse-link alias to canonical VM home when safe.
if [[ "${CONFIGURED_HOME}" != "${CANONICAL_HOME}" ]]; then
  echo "[lima-cloud-init] keeping canonical VM home ${CANONICAL_HOME}; treating configured home as alias: ${CONFIGURED_HOME}"
  if [[ -e "${CONFIGURED_HOME}" && ! -L "${CONFIGURED_HOME}" ]]; then
    echo "[lima-cloud-init] INFO: configured home exists and is not a symlink, keeping as-is: ${CONFIGURED_HOME}" >&2
  else
    mkdir -p "$(dirname "${CONFIGURED_HOME}")"
    ln -sfn "${CANONICAL_HOME}" "${CONFIGURED_HOME}"
    echo "[lima-cloud-init] configured home alias: ${CONFIGURED_HOME} -> ${CANONICAL_HOME}"
  fi
fi

# Fix permissions for canonical VM home directory
VM_HOME="${CANONICAL_HOME}"
if [[ -d "${VM_HOME}" ]]; then
  # shellcheck disable=SC2153
  chown "${LIMA_CIDATA_UID}:${LIMA_CIDATA_GID}" "${VM_HOME}" || true
  for subdir in .config .xdg .cache .local .local/share; do
    mkdir -p "${VM_HOME}/${subdir}"
    chown "${LIMA_CIDATA_UID}:${LIMA_CIDATA_GID}" "${VM_HOME}/${subdir}"
    chmod 755 "${VM_HOME}/${subdir}"
  done
fi

# Setup Lima shared mounts (virtiofs or 9p)
mkdir -p /run/udev/rules.d /run/systemd/system /mnt

yq -r '.mounts[] | @tsv' "${LIMA_CIDATA_MNT}/user-data" | \
while IFS=$'\t' read -r what where fstype fsopts; do
  if [[ -z "${fstype}" || "${fstype}" == "null" ]]; then
    continue
  fi

  tag="${what}"
  mountpoint="${where}"
  unit_name="$(systemd-escape --suffix=mount --path "${mountpoint}")"

  options=""
  unit_directives=""
  # normalise fsopts input (may be null)
  if [[ "${fsopts}" != "" && "${fsopts}" != "null" ]]; then
    fsopts_normalised="${fsopts}"
  else
    fsopts_normalised=""
  fi

  for fsopt in $(echo "${fsopts_normalised}" | tr ', ' '\n' | grep -v '^$'); do
    case "${fsopt}" in
      rw|ro|relatime|noatime|nodiratime|discard|sync|async|dirsync|remount|bind|move|defaults|_netdev|nofail|noauto)
        options+="${options:+,}${fsopt}" ;;
      x-systemd.requires=*) unit_directives+="Requires=${fsopt#x-systemd.requires=}\n" ;;
      x-systemd.after=*)    unit_directives+="After=${fsopt#x-systemd.after=}\n" ;;
      x-systemd.before=*)   unit_directives+="Before=${fsopt#x-systemd.before=}\n" ;;
      0|1) : ;;
      *) options+="${options:+,}${fsopt}" ;;
    esac
  done

  case "${fstype}" in
    virtiofs)
      cat > "/run/udev/rules.d/99-virtiofs-${tag}.rules" <<RULE
SUBSYSTEM=="virtio", DRIVER=="virtiofs", ATTR{tag}=="${tag}", TAG+="systemd", ENV{SYSTEMD_WANTS}+="${unit_name}"
RULE

      cat > "/run/systemd/system/${unit_name}" <<UNIT
[Unit]
Description=Virtiofs mount ${mountpoint} using ${tag} tag
DefaultDependencies=no
${unit_directives}
ConditionCapability=CAP_SYS_ADMIN
Before=sysinit.target
[Mount]
What=${tag}
Where=${mountpoint}
Type=virtiofs
Options=${options}
[Install]
WantedBy=multi-user.target
UNIT

      cat > "/run/systemd/system/${unit_name%.mount}.automount" <<AUTO
[Unit]
Description=Automount for ${mountpoint}
[Automount]
Where=${mountpoint}
[Install]
WantedBy=multi-user.target
AUTO

      mkdir -p "${mountpoint}"
      systemctl daemon-reload
      systemctl enable --runtime --now "${unit_name%.mount}.mount" "${unit_name%.mount}.automount" || true
      ;;
    9p)
      cat > "/run/systemd/system/${unit_name}" <<UNIT
[Unit]
Description=9p mount ${mountpoint} using ${tag} tag
DefaultDependencies=no
After=local-fs.target
${unit_directives}
[Mount]
What=${tag}
Where=${mountpoint}
Type=9p
Options=${options:-trans=virtio,version=9p2000.L,msize=262144}
[Install]
WantedBy=multi-user.target
UNIT

      cat > "/run/systemd/system/${unit_name%.mount}.automount" <<AUTO
[Unit]
Description=Automount for ${mountpoint}
[Automount]
Where=${mountpoint}
[Install]
WantedBy=multi-user.target
AUTO

      mkdir -p "${mountpoint}"
      systemctl daemon-reload
      systemctl enable --runtime --now "${unit_name%.mount}.automount" || true
      ;;
    *)
      # Unknown fstype; skip to avoid interfering with future Lima features
      continue
      ;;
  esac
done

udevadm control --reload-rules

cp "${LIMA_CIDATA_MNT}/meta-data" /run/lima-ssh-ready
cp "${LIMA_CIDATA_MNT}/meta-data" /run/lima-boot-done
