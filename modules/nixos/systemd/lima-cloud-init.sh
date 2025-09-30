#!/usr/bin/env bash
set -xe -o pipefail

# lima-cloud-init wrapper script extracted from Nix module (@codebase)
# Uses runtime PATH from systemd unit or wrapper runtimeInputs.

LIMA_CIDATA_MNT="${LIMA_CIDATA_MNT:-/mnt/lima-cidata}"
LIMA_CIDATA_DEV="${LIMA_CIDATA_DEV:-/dev/disk/by-label/cidata}"

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
    printf '%s\n' 'PATH=/run/wrappers/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin' >> "${PARAM_ENV_FILE}"
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

if id -u "${LIMA_CIDATA_USER}" &>/dev/null; then
  EXISTING_UID=$(id -u "${LIMA_CIDATA_USER}")
  if [[ "${EXISTING_UID}" != "${LIMA_CIDATA_UID}" ]]; then
    echo "[lima-cloud-init] WARNING: existing UID ${EXISTING_UID} != requested ${LIMA_CIDATA_UID}" >&2
    LIMA_CIDATA_UID=${EXISTING_UID}
	LIMA_CIDATA_GID=$(id -g "${LIMA_CIDATA_USER}")
  fi
else
  useradd --home-dir "${LIMA_CIDATA_HOMEDIR}" --create-home --uid "${LIMA_CIDATA_UID}" "${LIMA_CIDATA_USER}"
fi

usermod -a -G wheel "${LIMA_CIDATA_USER}" || true
usermod -a -G users "${LIMA_CIDATA_USER}" || true

ln -fs /run/current-system/sw/bin/bash /bin/bash
ln -fs /run/wrappers/bin/sudo /bin/sudo

# Setup SSH
install -d -m 755 "/etc/ssh/authorized_keys.d"
yq eval '.users[].ssh-authorized-keys[]' "${LIMA_CIDATA_MNT}/user-data" > "/etc/ssh/authorized_keys.d/${LIMA_CIDATA_USER}"
chmod a+r "/etc/ssh/authorized_keys.d/${LIMA_CIDATA_USER}"

# Fix permissions for Darwin host shared home directory
DARWIN_HOME="/home/${LIMA_CIDATA_USER}"
if [[ -d "${DARWIN_HOME}" ]]; then
  # shellcheck disable=SC2153
  chown "${LIMA_CIDATA_UID}:${LIMA_CIDATA_GID}" "${DARWIN_HOME}" || true
  for subdir in .config .xdg .cache .local .local/share; do
    mkdir -p "${DARWIN_HOME}/${subdir}"
    chown "${LIMA_CIDATA_UID}:${LIMA_CIDATA_GID}" "${DARWIN_HOME}/${subdir}"
    chmod 755 "${DARWIN_HOME}/${subdir}"
  done
fi

# Setup virtiofs mounts
mkdir -p /run/udev/rules.d /run/systemd/system /mnt

yq -r '.mounts[] | select(.[2] == "virtiofs") | @tsv' "${LIMA_CIDATA_MNT}/user-data" | \
while IFS=$'\t' read -r what where _fstype fsopts; do
  tag="${what}"
  mountpoint="${where}"
  unit_name="$(systemd-escape --suffix=mount --path "${mountpoint}")"

  options=""
  unit_directives=""
  for fsopt in $(echo "${fsopts}" | tr ', ' '\n' | grep -v '^$'); do
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
done

udevadm control --reload-rules

cp "${LIMA_CIDATA_MNT}/meta-data" /run/lima-ssh-ready
cp "${LIMA_CIDATA_MNT}/meta-data" /run/lima-boot-done
