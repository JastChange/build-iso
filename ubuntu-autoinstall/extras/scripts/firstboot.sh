#!/usr/bin/env bash
# 在目标系统第一次启动后执行。此时已进入最终内核，适合编译/安装驱动模块。
set -euo pipefail

EXTRAS_DIR="${EXTRAS_DIR:-/opt/extras}"
LOG_FILE="${LOG_FILE:-/var/log/ubuntu-autoinstall-firstboot.log}"
STATE_DIR="/var/lib/ubuntu-autoinstall"
DONE_FILE="${STATE_DIR}/firstboot.done"
FAILURE_FILE="${STATE_DIR}/driver-failures.log"
CONFIG_FILE="${EXTRAS_DIR}/config/firstboot.env"
LIB_FILE="${EXTRAS_DIR}/lib/iso-functions.sh"

FIRSTBOOT_REBOOT="${FIRSTBOOT_REBOOT:-true}"
CLEANUP_EXTRAS="${CLEANUP_EXTRAS:-true}"
DRIVER_FAILURE_POLICY="${DRIVER_FAILURE_POLICY:-continue}"
FIRSTBOOT_DEBUG="${FIRSTBOOT_DEBUG:-true}"
DRIVER_OFFLINE_MODE="${DRIVER_OFFLINE_MODE:-true}"
DEBUG_DIR="${DEBUG_DIR:-/var/log/ubuntu-autoinstall-debug}"
MLNX_INSTALL_PROFILE="${MLNX_INSTALL_PROFILE:-basic}"
RETAIN_ON_DRIVER_FAILURE="${RETAIN_ON_DRIVER_FAILURE:-true}"
REBOOT_ON_DRIVER_FAILURE="${REBOOT_ON_DRIVER_FAILURE:-false}"
MARK_DONE_ON_DRIVER_FAILURE="${MARK_DONE_ON_DRIVER_FAILURE:-false}"
KEEP_SERVICE_ON_DRIVER_FAILURE="${KEEP_SERVICE_ON_DRIVER_FAILURE:-true}"
DRIVER_FAILURES=0

mkdir -p "$(dirname "${LOG_FILE}")" "${STATE_DIR}" "${DEBUG_DIR}"

log() {
  echo "[$(date '+%F %T')] $*" | tee -a "${LOG_FILE}"
}

if [[ -f "${LIB_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${LIB_FILE}"
else
  log "错误：缺少共享函数库：${LIB_FILE}"
  exit 1
fi

enable_debug_trace() {
  if ! bool_is_true "${FIRSTBOOT_DEBUG}"; then
    return 0
  fi

  exec {FIRSTBOOT_TRACE_FD}>>"${DEBUG_DIR}/firstboot.trace"
  export BASH_XTRACEFD="${FIRSTBOOT_TRACE_FD}"
  PS4='+ [${BASH_SOURCE##*/}:${LINENO}] '
  set -x
}

on_error() {
  local line="$1"
  local command="$2"
  local status="$3"

  log "错误：firstboot 在第 ${line} 行失败，退出码 ${status}，命令：${command}"
}

collect_firstboot_snapshot() {
  local snapshot="${DEBUG_DIR}/firstboot-system.txt"
  local kernel

  kernel="$(uname -r)"
  {
    echo "===== firstboot snapshot $(date '+%F %T') ====="
    echo "hostname: $(hostname 2>/dev/null || true)"
    echo "kernel: $(uname -a)"
    echo
    echo "----- /etc/os-release -----"
    cat /etc/os-release 2>/dev/null || true
    echo
    echo "----- /proc/cmdline -----"
    cat /proc/cmdline 2>/dev/null || true
    echo
    echo "----- firstboot config -----"
    printf 'EXTRAS_DIR=%s\n' "${EXTRAS_DIR}"
    printf 'FIRSTBOOT_REBOOT=%s\n' "${FIRSTBOOT_REBOOT}"
    printf 'CLEANUP_EXTRAS=%s\n' "${CLEANUP_EXTRAS}"
    printf 'DRIVER_FAILURE_POLICY=%s\n' "${DRIVER_FAILURE_POLICY}"
    printf 'FIRSTBOOT_DEBUG=%s\n' "${FIRSTBOOT_DEBUG}"
    printf 'DRIVER_OFFLINE_MODE=%s\n' "${DRIVER_OFFLINE_MODE}"
    printf 'DEBUG_DIR=%s\n' "${DEBUG_DIR}"
    printf 'MLNX_INSTALL_PROFILE=%s\n' "${MLNX_INSTALL_PROFILE}"
    printf 'RETAIN_ON_DRIVER_FAILURE=%s\n' "${RETAIN_ON_DRIVER_FAILURE}"
    printf 'REBOOT_ON_DRIVER_FAILURE=%s\n' "${REBOOT_ON_DRIVER_FAILURE}"
    printf 'MARK_DONE_ON_DRIVER_FAILURE=%s\n' "${MARK_DONE_ON_DRIVER_FAILURE}"
    printf 'KEEP_SERVICE_ON_DRIVER_FAILURE=%s\n' "${KEEP_SERVICE_ON_DRIVER_FAILURE}"
    echo
    echo "----- drivers directory -----"
    find "${EXTRAS_DIR}/drivers" -maxdepth 1 -type f -printf '%p %s bytes\n' 2>/dev/null || true
    echo
    echo "----- kernel headers -----"
    ls -ld "/lib/modules/${kernel}" "/lib/modules/${kernel}/build" "/usr/src/linux-headers-${kernel}" 2>/dev/null || true
    echo
    echo "----- selected packages -----"
    dpkg-query -W -f='${binary:Package}\t${Version}\t${Status}\n' \
      dkms build-essential gcc make "linux-headers-${kernel}" \
      nvidia-driver-* mlnx-ofed-* ofed-scripts rdma-core libibverbs1 2>/dev/null || true
    echo
    echo "----- dkms status -----"
    dkms status 2>/dev/null || true
    echo
    echo "----- loaded modules -----"
    lsmod 2>/dev/null | grep -E 'nvidia|nouveau|mlx|ib_|rdma' || true
    echo
    echo "----- pci devices -----"
    lspci -nn 2>/dev/null | grep -Ei 'nvidia|mellanox|infiniband|ethernet' || true
    echo
    echo "----- secure boot -----"
    if command -v mokutil >/dev/null 2>&1; then
      mokutil --sb-state 2>&1 || true
    else
      echo "mokutil not installed"
    fi
    echo
    echo "----- network -----"
    ip -br addr 2>/dev/null || true
    ip route 2>/dev/null || true
    echo
    echo "----- disk usage -----"
    df -h / /var /tmp /opt 2>/dev/null || true
  } >> "${snapshot}" 2>&1

  log "已写入 firstboot 调试快照：${snapshot}"
}

load_firstboot_config() {
  if [[ -f "${CONFIG_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${CONFIG_FILE}"
    log "已加载首次开机配置：${CONFIG_FILE}"
  fi
}

run_driver_installer() {
  local name="$1"
  local slug="$2"
  local status
  local component_log="${DEBUG_DIR}/${slug}.stdout.log"
  shift 2

  log "开始安装 ${name}，组件日志：${component_log}"
  set +e
  DRIVER_DEBUG_DIR="${DEBUG_DIR}" FIRSTBOOT_DEBUG="${FIRSTBOOT_DEBUG}" DRIVER_OFFLINE_MODE="${DRIVER_OFFLINE_MODE}" MLNX_INSTALL_PROFILE="${MLNX_INSTALL_PROFILE}" \
    "$@" 2>&1 | tee -a "${LOG_FILE}" "${component_log}"
  status=${PIPESTATUS[0]}
  set -e

  if [[ "${status}" -eq 0 ]]; then
    log "${name} 安装完成"
    return 0
  fi

  DRIVER_FAILURES=$((DRIVER_FAILURES + 1))
  printf '[%s] %s failed, exit_code=%s, command=%q\n' \
    "$(date '+%F %T')" "${name}" "${status}" "$*" >> "${FAILURE_FILE}"
  log "${name} 安装失败，退出码 ${status}，详情见 ${component_log}"
  if [[ "${DRIVER_FAILURE_POLICY}" == "fail" ]]; then
    return "${status}"
  fi
  return 0
}

install_mlnx_if_present() {
  local mlnx_package=""

  mlnx_package="$(find "${EXTRAS_DIR}/drivers" -maxdepth 1 -type f \( -name 'MLNX_OFED_LINUX-*.tgz' -o -name 'MLNX_OFED_LINUX-*.iso' \) 2>/dev/null | sort | head -1 || true)"
  if [[ -z "${mlnx_package}" ]]; then
    log "未发现 Mellanox OFED，跳过"
    return 0
  fi

  run_driver_installer "Mellanox OFED" "mlnx-ofed" bash "${EXTRAS_DIR}/scripts/install-mlnx.sh" "${mlnx_package}"
}

install_nvidia_if_present() {
  local nvidia_run=""

  nvidia_run="$(ls "${EXTRAS_DIR}/drivers"/NVIDIA-Linux-x86_64-*.run 2>/dev/null | head -1 || true)"
  if [[ -z "${nvidia_run}" ]]; then
    log "未发现 NVIDIA 驱动，跳过"
    return 0
  fi

  run_driver_installer "NVIDIA 驱动" "nvidia" bash "${EXTRAS_DIR}/scripts/install-nvidia.sh" "${nvidia_run}"
}

cleanup_firstboot_residue() {
  local keep_service="${1:-false}"

  log "开始清理首次开机残留文件"

  if bool_is_true "${keep_service}"; then
    log "保留 iso-firstboot.service，便于排查后手动重跑"
  else
    systemctl disable iso-firstboot.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/multi-user.target.wants/iso-firstboot.service
    rm -f /etc/systemd/system/iso-firstboot.service
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi

  rm -f /etc/apt/sources.list.d/ubuntu-autoinstall-local.list
  rm -f /usr/share/keyrings/ubuntu-autoinstall-local-repo.gpg
  rm -f /etc/apt/trusted.gpg.d/repo-signing.gpg
  apt-get clean >/dev/null 2>&1 || true
  rm -rf /var/lib/apt/lists/* /tmp/ofed-build /tmp/MLNX_OFED* /tmp/NVIDIA-Linux* 2>/dev/null || true

  if bool_is_true "${CLEANUP_EXTRAS}"; then
    log "删除 ${EXTRAS_DIR}"
    safe_remove_path "${EXTRAS_DIR}" || log "跳过删除不安全路径：${EXTRAS_DIR}"
  else
    log "CLEANUP_EXTRAS=false，保留 ${EXTRAS_DIR}"
  fi
}

request_reboot_if_needed() {
  if bool_is_true "${FIRSTBOOT_REBOOT}"; then
    log "首次开机任务完成，准备重启服务器"
    systemctl reboot
  else
    log "FIRSTBOOT_REBOOT=false，不自动重启"
  fi
}

finalize_driver_failures() {
  if [[ "${DRIVER_FAILURES}" -eq 0 ]]; then
    date '+%F %T' > "${DONE_FILE}"
    return 0
  fi

  log "检测到 ${DRIVER_FAILURES} 个驱动安装失败，失败摘要：${FAILURE_FILE}"
  collect_firstboot_snapshot

  if bool_is_true "${RETAIN_ON_DRIVER_FAILURE}"; then
    CLEANUP_EXTRAS="false"
    log "RETAIN_ON_DRIVER_FAILURE=true，失败后保留 ${EXTRAS_DIR}"
  fi

  if bool_is_true "${REBOOT_ON_DRIVER_FAILURE}"; then
    log "REBOOT_ON_DRIVER_FAILURE=true，失败后仍按 FIRSTBOOT_REBOOT 策略处理"
  else
    FIRSTBOOT_REBOOT="false"
    log "REBOOT_ON_DRIVER_FAILURE=false，失败后不自动重启，便于现场排查"
  fi

  if bool_is_true "${MARK_DONE_ON_DRIVER_FAILURE}"; then
    date '+%F %T' > "${DONE_FILE}"
    log "MARK_DONE_ON_DRIVER_FAILURE=true，失败后仍写入 done 文件"
  else
    log "MARK_DONE_ON_DRIVER_FAILURE=false，失败后不写入 done 文件"
  fi
}

main() {
  if [[ -f "${DONE_FILE}" ]]; then
    log "首次开机任务已完成，跳过"
    exit 0
  fi

  rm -f "${FAILURE_FILE}"
  log "===== firstboot.sh 开始，当前内核：$(uname -r) ====="
  load_firstboot_config
  mkdir -p "${DEBUG_DIR}"
  enable_debug_trace
  trap 'on_error "${LINENO}" "${BASH_COMMAND}" "$?"' ERR
  collect_firstboot_snapshot

  if ! install_mlnx_if_present; then
    printf '[%s] Mellanox OFED stopped remaining driver installs because DRIVER_FAILURE_POLICY=fail\n' \
      "$(date '+%F %T')" >> "${FAILURE_FILE}"
  fi
  if [[ "${DRIVER_FAILURE_POLICY}" != "fail" || "${DRIVER_FAILURES}" -eq 0 ]]; then
    if ! install_nvidia_if_present; then
      printf '[%s] NVIDIA stopped firstboot because DRIVER_FAILURE_POLICY=fail\n' \
        "$(date '+%F %T')" >> "${FAILURE_FILE}"
    fi
  fi

  finalize_driver_failures
  cleanup_firstboot_residue "$([[ "${DRIVER_FAILURES}" -gt 0 ]] && bool_is_true "${KEEP_SERVICE_ON_DRIVER_FAILURE}" && echo true || echo false)"
  log "===== firstboot.sh 完成 ====="

  if [[ "${DRIVER_FAILURE_POLICY}" == "fail" && "${DRIVER_FAILURES}" -gt 0 ]]; then
    log "DRIVER_FAILURE_POLICY=fail，首次开机任务以失败退出"
    exit 1
  fi

  request_reboot_if_needed
}

main "$@"
