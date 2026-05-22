#!/usr/bin/env bash

bool_is_true() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

normalize_kernel_abi() {
  local version="${1:-}"
  local flavor="${2:-generic}"

  [[ -n "${version}" ]] || return 1

  if [[ "${version}" == *"-${flavor}" ]]; then
    printf '%s\n' "${version}"
  else
    printf '%s-%s\n' "${version}" "${flavor}"
  fi
}

kernel_base_version() {
  local kernel_abi="${1:?kernel ABI is required}"
  local flavor="${2:-generic}"

  printf '%s\n' "${kernel_abi%-${flavor}}"
}

kernel_required_packages() {
  local kernel_abi="${1:?kernel ABI is required}"
  local flavor="${2:-generic}"
  local kernel_base

  kernel_base="$(kernel_base_version "${kernel_abi}" "${flavor}")"

  printf '%s\n' \
    "linux-headers-${kernel_base}" \
    "linux-headers-${kernel_abi}" \
    "linux-modules-${kernel_abi}" \
    "linux-image-${kernel_abi}"
}

kernel_optional_packages() {
  local kernel_abi="${1:?kernel ABI is required}"

  printf '%s\n' "linux-modules-extra-${kernel_abi}"
}

safe_remove_path() {
  local path="${1:-}"

  [[ -n "${path}" ]] || return 1
  [[ "${path}" != "/" ]] || return 1
  [[ "${path}" != "/opt" ]] || return 1
  [[ "${path}" == /opt/* || "${path}" == /var/tmp/* || "${path}" == /tmp/* ]] || return 1

  rm -rf -- "${path}"
}

register_firstboot_service() {
  local root_dir="${1:-/}"
  local extras_dir="${2:-/opt/extras}"
  local firstboot_reboot="${3:-true}"
  local systemd_dir="${root_dir%/}/etc/systemd/system"
  local service_file="${systemd_dir}/iso-firstboot.service"
  local wants_dir="${systemd_dir}/multi-user.target.wants"
  local wants_link="${wants_dir}/iso-firstboot.service"

  mkdir -p "${wants_dir}"

  cat > "${service_file}" <<EOF
[Unit]
Description=Ubuntu autoinstall first boot tasks
After=local-fs.target network-online.target
Wants=network-online.target
ConditionPathExists=${extras_dir}/scripts/firstboot.sh
ConditionPathExists=!/var/lib/ubuntu-autoinstall/firstboot.done

[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutStartSec=0
Environment=EXTRAS_DIR=${extras_dir}
Environment=FIRSTBOOT_REBOOT=${firstboot_reboot}
ExecStart=${extras_dir}/scripts/firstboot.sh

[Install]
WantedBy=multi-user.target
EOF

  chmod 0644 "${service_file}"
  ln -sfn ../iso-firstboot.service "${wants_link}"
}
