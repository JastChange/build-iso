#!/usr/bin/env bash
# install-nvidia.sh <NVIDIA-Linux-x86_64-*.run>
set -euo pipefail

NVIDIA_RUN="${1:?用法: $0 <NVIDIA-Linux-x86_64-*.run>}"
LOG="/var/log/nvidia-install.log"
STATE_DIR="/var/lib/ubuntu-autoinstall"
DONE_FILE="${STATE_DIR}/nvidia.done"
DEBUG_DIR="${DRIVER_DEBUG_DIR:-/var/log/ubuntu-autoinstall-debug}"
FIRSTBOOT_DEBUG="${FIRSTBOOT_DEBUG:-true}"
DRIVER_OFFLINE_MODE="${DRIVER_OFFLINE_MODE:-true}"

log() {
  echo "[$(date '+%F %T')] $*" | tee -a "${LOG}"
}

bool_true() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

enable_debug_trace() {
  if ! bool_true "${FIRSTBOOT_DEBUG}"; then
    return 0
  fi

  exec {NVIDIA_TRACE_FD}>>"${DEBUG_DIR}/nvidia.trace"
  export BASH_XTRACEFD="${NVIDIA_TRACE_FD}"
  PS4='+ [${BASH_SOURCE##*/}:${LINENO}] '
  set -x
}

run_logged() {
  local status

  log "+ $*"
  set +e
  "$@" 2>&1 | tee -a "${LOG}"
  status=${PIPESTATUS[0]}
  set -e
  log "命令退出码 ${status}: $*"
  return "${status}"
}

collect_nvidia_snapshot() {
  local snapshot="${DEBUG_DIR}/nvidia-system.txt"
  local kernel

  kernel="$(uname -r)"
  {
    echo "===== NVIDIA snapshot $(date '+%F %T') ====="
    echo "installer: ${NVIDIA_RUN}"
    echo "installer_size: $(stat -c '%s' "${NVIDIA_RUN}" 2>/dev/null || true)"
    echo "driver_offline_mode: ${DRIVER_OFFLINE_MODE}"
    "${NVIDIA_RUN}" --version 2>&1 || true
    echo
    echo "----- os-release -----"
    cat /etc/os-release 2>/dev/null || true
    echo
    echo "----- kernel -----"
    uname -a
    ls -ld "/lib/modules/${kernel}" "/lib/modules/${kernel}/build" "/usr/src/linux-headers-${kernel}" 2>/dev/null || true
    echo
    echo "----- compiler and dkms -----"
    gcc --version 2>/dev/null | head -1 || true
    make --version 2>/dev/null | head -1 || true
    dkms status 2>/dev/null || true
    echo
    echo "----- selected packages -----"
    dpkg-query -W -f='${binary:Package}\t${Version}\t${Status}\n' \
      dkms build-essential gcc make pkg-config libglvnd-dev kmod initramfs-tools \
      "linux-headers-${kernel}" 2>/dev/null || true
    echo
    echo "----- pci nvidia devices -----"
    lspci -nn 2>/dev/null | grep -Ei 'nvidia|3d controller|vga' || true
    echo
    echo "----- modules before install -----"
    lsmod 2>/dev/null | grep -E 'nvidia|nouveau' || true
    echo
    echo "----- modprobe config -----"
    grep -R . /etc/modprobe.d 2>/dev/null | grep -Ei 'nvidia|nouveau' || true
    echo
    echo "----- secure boot -----"
    if command -v mokutil >/dev/null 2>&1; then
      mokutil --sb-state 2>&1 || true
    else
      echo "mokutil not installed"
    fi
    echo
    echo "----- disk usage -----"
    df -h / /var /tmp 2>/dev/null || true
  } >> "${snapshot}" 2>&1

  log "已写入 NVIDIA 调试快照：${snapshot}"
}

collect_nvidia_artifacts() {
  local artifact_dir="${DEBUG_DIR}/nvidia-artifacts"

  mkdir -p "${artifact_dir}"
  cp -a /var/log/nvidia-installer.log* "${artifact_dir}/" 2>/dev/null || true
  cp -a "${LOG}" "${artifact_dir}/" 2>/dev/null || true
  dmesg > "${artifact_dir}/dmesg.log" 2>/dev/null || true
  dkms status > "${artifact_dir}/dkms-status.txt" 2>/dev/null || true
  log "已归档 NVIDIA 调试文件：${artifact_dir}"
}

on_error() {
  local line="$1"
  local command="$2"
  local status="$3"

  log "错误：NVIDIA 安装在第 ${line} 行失败，退出码 ${status}，命令：${command}"
  collect_nvidia_artifacts
}

ensure_packages() {
  local packages=("$@")
  local missing=()
  local package_name

  for package_name in "${packages[@]}"; do
    if ! dpkg -s "${package_name}" >/dev/null 2>&1; then
      missing+=("${package_name}")
    fi
  done

  if [[ "${#missing[@]}" -eq 0 ]]; then
    return 0
  fi

  log "NVIDIA 驱动缺失依赖：${missing[*]}"
  if bool_true "${DRIVER_OFFLINE_MODE}"; then
    log "DRIVER_OFFLINE_MODE=true，禁止首次开机阶段联网安装依赖"
    log "请将缺失包加入 ubuntu-autoinstall/extras/config/packages.list 或 extras/repo 后重新构建 ISO"
    return 1
  fi

  log "DRIVER_OFFLINE_MODE=false，尝试联网安装 NVIDIA 驱动缺失依赖"
  export DEBIAN_FRONTEND=noninteractive
  run_logged apt-get update
  run_logged apt-get install -y --no-install-recommends "${missing[@]}"
}

if [[ -f "${DONE_FILE}" ]]; then
  log "NVIDIA 驱动已安装，跳过"
  exit 0
fi

mkdir -p "${STATE_DIR}" "${DEBUG_DIR}"
enable_debug_trace
trap 'on_error "${LINENO}" "${BASH_COMMAND}" "$?"' ERR
chmod +x "${NVIDIA_RUN}"

log "NVIDIA 驱动安装包：$(basename "${NVIDIA_RUN}")"
log "当前运行内核：$(uname -r)"
collect_nvidia_snapshot

ensure_packages \
  build-essential dkms pkg-config libglvnd-dev kmod initramfs-tools \
  "linux-headers-$(uname -r)"

cat > /etc/modprobe.d/blacklist-nouveau.conf <<'EOF'
blacklist nouveau
blacklist lbm-nouveau
options nouveau modeset=0
alias nouveau off
EOF
run_logged update-initramfs -u || true

run_logged "${NVIDIA_RUN}" \
  -s \
  --dkms \
  --no-questions \
  --accept-license \
  --no-nouveau-check \
  --install-libglvnd

collect_nvidia_artifacts
run_logged depmod -a
run_logged update-initramfs -u || true
date '+%F %T' > "${DONE_FILE}"

log "NVIDIA 驱动安装完成"
