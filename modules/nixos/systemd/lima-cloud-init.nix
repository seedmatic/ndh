{ config, modulesPath, pkgs, lib, ... }:

let
  dollar = "$";

  LIMA_CIDATA_MNT = "/mnt/lima-cidata";
  LIMA_CIDATA_DEV = "/dev/disk/by-label/cidata";

  script = ''
        set -xe -o pipefail

        : Systemd service to reconfigure the system from lima-cloud-init userdata on startup using $PATH

        : Attempting to fetch configuration from LIMA user data...
        if [ -f ${LIMA_CIDATA_MNT}/lima.env ]; then
            echo "storage exists";
        else
            echo "storage not exists";
            exit 2
        fi

        : Extend path with required binaries
        export PATH=${
          pkgs.lib.makeBinPath [
            pkgs.bash
            pkgs.mount
            pkgs.rsync
            pkgs.shadow
            pkgs.sudo
            pkgs.util-linux
            pkgs.yq-go
            pkgs.zfs
            pkgs.zsh
          ]
        }:$PATH

        : Remount lima-cidata as overlay
        mkdir -p ${LIMA_CIDATA_MNT}-upper ${LIMA_CIDATA_MNT}-work
        mount -t overlay overlay -o lowerdir=${LIMA_CIDATA_MNT},upperdir=${LIMA_CIDATA_MNT}-upper,workdir=${LIMA_CIDATA_MNT}-work ${LIMA_CIDATA_MNT}
        trap "PATH=$PATH; umount ${LIMA_CIDATA_MNT}; rm -fr ${LIMA_CIDATA_MNT}-*" EXIT

        : Enforce plain mode and load lima.env
        yq --inplace --input-format=props --output-format=props eval '.LIMA_CIDATA_PLAIN=1' "${LIMA_CIDATA_MNT}"/lima.env
        sed --in-place 's/ = /=/' "${LIMA_CIDATA_MNT}"/lima.env
        source <( yq --input-format=props --output-format=shell ${LIMA_CIDATA_MNT}/lima.env )

        : Create user
        LIMA_CIDATA_HOMEDIR="/home/$LIMA_CIDATA_USER.linux"
        id -u "$LIMA_CIDATA_USER" >/dev/null 2>&1 || useradd --home-dir "$LIMA_CIDATA_HOMEDIR" --create-home --uid "$LIMA_CIDATA_UID" "$LIMA_CIDATA_USER"

        : Add user to sudoers
        usermod -a -G wheel $LIMA_CIDATA_USER
        usermod -a -G users $LIMA_CIDATA_USER

        : Fix symlink for /bin/bash
        ln -fs /run/current-system/sw/bin/bash /bin/bash

        : Create authorized_keys
        LIMA_CIDATA_SSHDIR="$LIMA_CIDATA_HOMEDIR"/.ssh
        mkdir -p -m 700 "$LIMA_CIDATA_SSHDIR"

        : Using yq to extract SSH keys and create authorized_keys file
        ${pkgs.yq-go}/bin/yq --from-file=<( cat <<EoF | cut -c 4-
        .users[] |
          select(.name == "$LIMA_CIDATA_USER") |
          .ssh-authorized-keys[]
    EoF
        ) "${LIMA_CIDATA_MNT}/user-data" > "$LIMA_CIDATA_SSHDIR/authorized_keys"
        LIMA_CIDATA_GID=$(id -g "$LIMA_CIDATA_USER")
        chown -R "$LIMA_CIDATA_UID:$LIMA_CIDATA_GID" "$LIMA_CIDATA_SSHDIR"
        chmod 600 "$LIMA_CIDATA_SSHDIR"/authorized_keys
        LIMA_SSH_KEYS_CONF=/etc/ssh/authorized_keys.d
        mkdir -p -m 700 "$LIMA_SSH_KEYS_CONF"
        cp "$LIMA_CIDATA_SSHDIR"/authorized_keys "$LIMA_SSH_KEYS_CONF/$LIMA_CIDATA_USER"

        : Generate udev rules and systemd mount units for virtiofs mounts from user-data
        mkdir -p /run/udev/rules.d /run/systemd/system /mnt

        ${pkgs.yq-go}/bin/yq -r '.mounts[] | select(.[2] == "virtiofs") | @tsv' ${LIMA_CIDATA_MNT}/user-data | \
        while IFS=$'\t' read -r what where fstype fsopts; do
          tag="${dollar}{what}"
          mountpoint="${dollar}{where}"
          unit_name="$(systemd-escape --suffix=mount --path "${dollar}{mountpoint}")"

          : Parse mount options
          options=""
          unit_directives=""
          for fsopt in $(echo "${dollar}{fsopts}" | tr ', ' '\n' | grep -v '^$'); do
            case "${dollar}{fsopt}" in
              rw|ro|relatime|noatime|nodiratime|discard|sync|async|dirsync|remount|bind|move|defaults|_netdev|nofail|noauto)
                options="${dollar}{options},${dollar}{fsopt}"
                ;;
              x-systemd.requires=*)
                unit_directives="${dollar}{unit_directives}Requires=${dollar}{fsopt#x-systemd.requires=}\n"
                ;;
              x-systemd.after=*)
                unit_directives="${dollar}{unit_directives}After=${dollar}{fsopt#x-systemd.after=}\n"
                ;;
              x-systemd.before=*)
                unit_directives="${dollar}{unit_directives}Before=${dollar}{fsopt#x-systemd.before=}\n"
                ;;
              0|1)
                : skip fstab dump pass fields
                ;;
              *)
                options="${dollar}{options},${dollar}{fsopt}"
                ;;
            esac
          done
          options="${dollar}{options#,}" # remove leading comma

          : Create udev rule for this virtiofs tag
          cat <<EoF | cut -c 7- | tee "/run/udev/rules.d/99-virtiofs-${dollar}{tag}.rules"
          SUBSYSTEM=="virtio", DRIVER=="virtiofs", ATTR{tag}=="${dollar}{tag}", TAG+="systemd", ENV{SYSTEMD_WANTS}+="${dollar}{unit_name}"
    EoF

          : Create systemd mount unit
          cat <<EoF | cut -c 7- | tee "/run/systemd/system/${dollar}{unit_name}"
          [Unit]
          Description=Virtiofs mount ${dollar}{mountpoint} using ${dollar}{tag} tag
          DefaultDependencies=no
          ${dollar}{unit_directives}
          ConditionCapability=CAP_SYS_ADMIN
          Before=sysinit.target
          [Mount]
          What=${dollar}{tag}
          Where=${dollar}{mountpoint}
          Type=virtiofs
          Options=${dollar}{options}
          [Install]
          WantedBy=multi-user.target
    EoF

          : Create systemd automount unit
          cat <<EoF | cut -c 7- | tee "/run/systemd/system/${dollar}{unit_name%.mount}.automount"
          [Unit]
          Description=Automount for ${dollar}{mountpoint}
          [Automount]
          Where=${dollar}{mountpoint}
          [Install]
          WantedBy=multi-user.target
    EoF

          : Enable and start the automount unit
          mkdir -p "${dollar}{mountpoint}"
          systemctl daemon-reload
          systemctl enable --runtime --now "${dollar}{unit_name%.mount}.mount" "${dollar}{unit_name%.mount}.automount" || 
            : ignore systemctl load failure
        done

        : Reload udev to pick up new units and rules
        udevadm control --reload-rules

        : Launch the boot script
        env -S LIMA_CIDATA_MNT=${LIMA_CIDATA_MNT} bash -ex -o pipefail ${LIMA_CIDATA_MNT}/boot.sh
  '';
in {
  imports = [ ];

  systemd.services.lima-cloud-init = {
    inherit script;
    description =
      "Reconfigure the system from lima-cloud-init userdata on startup";

    after = [ "network-pre.target" "zfs-import.target" ];
    before = [ "multi-user.target" "replay-virtiofs-udev.service" ];
    wantedBy = [ "multi-user.target" ];

    restartIfChanged = true;

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    unitConfig = { X-StopOnRemoval = false; };
  };

  systemd.services.replay-virtiofs-udev = {
    description = "Replay virtiofs udev events after boot";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.systemd}/bin/udevadm trigger -s virtio -c bind";
    };
  };

  fileSystems = {
    "${LIMA_CIDATA_MNT}" = {
      device = "${LIMA_CIDATA_DEV}";
      fsType = "auto";
      options =
        [ "ro" "mode=0700" "dmode=0700" "overriderockperm" "exec" "uid=0" ];
    };
  };

  environment.etc = {
    environment.source = "${LIMA_CIDATA_MNT}/etc_environment";
  };

  networking.nat.enable = true;

  environment.systemPackages = with pkgs; [ bash sshfs fuse3 git ];

  boot.kernel.sysctl = {
    "kernel.unprivileged_userns_clone" = 1;
    "net.ipv4.ping_group_range" = "0 2147483647";
    "net.ipv4.ip_unprivileged_port_start" = 0;
  };
}
