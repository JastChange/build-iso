#!/usr/bin/env bash
# 在目标系统第一次启动后执行。此时已进入最终内核，适合编译/安装驱动模块。
set -euo pipefail

EXTRAS_DIR="${EXTRAS_DIR:-/opt/extras}"
LOG_FILE="${LOG_FILE:-/var/log/ubuntu-autoinstall-firstboot.log}"
STATE_DIR="/var/lib/ubuntu-autoinstall"
DONE_FILE="${STATE_DIR}/firstboot.done"
FAILURE_FILE="${STATE_DIR}/driver-failures.log"
CONFIG_FILE="${EXTRAS_DIR}/config/firstboot.env"
KERNEL_CONFIG_FILE="${EXTRAS_DIR}/config/kernel.env"
LIB_FILE="${EXTRAS_DIR}/lib/iso-functions.sh"
KERNEL_MISMATCH_FILE="${STATE_DIR}/kernel-mismatch.log"
VERIFY_FAILURE_FILE="${STATE_DIR}/verification-failure.log"
VERIFY_LOG_FILE="${VERIFY_LOG_FILE:-/var/log/ubuntu-autoinstall-verify.log}"

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
KERNEL_VERSION="${KERNEL_VERSION:-}"
KERNEL_FLAVOR="${KERNEL_FLAVOR:-generic}"
INSTALL_MODE="${INSTALL_MODE:-auto}"
KERNEL_HOLD="${KERNEL_HOLD:-true}"
FINAL_VERIFY_ENABLED="${FINAL_VERIFY_ENABLED:-true}"
FINAL_VERIFY_SCRIPT="${FINAL_VERIFY_SCRIPT:-${EXTRAS_DIR}/scripts/verify-install.sh}"
DRIVER_FAILURES=0

mkdir -p "$(dirname "${LOG_FILE}")" "${STATE_DIR}"

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

  mkdir -p "${DEBUG_DIR}"
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

  if ! bool_is_true "${FIRSTBOOT_DEBUG}"; then
    return 0
  fi

  mkdir -p "${DEBUG_DIR}"
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
    printf 'KERNEL_VERSION=%s\n' "${KERNEL_VERSION}"
    printf 'KERNEL_FLAVOR=%s\n' "${KERNEL_FLAVOR}"
    printf 'INSTALL_MODE=%s\n' "${INSTALL_MODE}"
    printf 'KERNEL_HOLD=%s\n' "${KERNEL_HOLD}"
    printf 'FINAL_VERIFY_ENABLED=%s\n' "${FINAL_VERIFY_ENABLED}"
    printf 'FINAL_VERIFY_SCRIPT=%s\n' "${FINAL_VERIFY_SCRIPT}"
    printf 'VERIFY_LOG_FILE=%s\n' "${VERIFY_LOG_FILE}"
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

load_kernel_config() {
  if [[ -f "${KERNEL_CONFIG_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${KERNEL_CONFIG_FILE}"
    log "已加载内核配置：${KERNEL_CONFIG_FILE}"
  else
    log "未发现内核配置文件，使用默认内核行为"
  fi
}

validate_target_kernel_for_drivers() {
  local target_kernel current_kernel

  if [[ -z "${KERNEL_VERSION}" ]]; then
    log "未配置 KERNEL_VERSION，跳过驱动前内核校验"
    return 0
  fi

  target_kernel="$(normalize_kernel_abi "${KERNEL_VERSION}" "${KERNEL_FLAVOR}")"
  current_kernel="$(uname -r)"

  if [[ "${current_kernel}" == "${target_kernel}" ]]; then
    log "当前运行内核符合目标内核：${target_kernel}"
    rm -f "${KERNEL_MISMATCH_FILE}"
    return 0
  fi

  {
    printf '[%s] target_kernel=%s current_kernel=%s\n' "$(date '+%F %T')" "${target_kernel}" "${current_kernel}"
    printf '当前内核不符合目标内核，已阻止 NVIDIA/Mellanox 驱动安装。\n'
  } >> "${KERNEL_MISMATCH_FILE}"
  log "错误：当前运行内核 ${current_kernel} 不是目标内核 ${target_kernel}，停止安装 NVIDIA/Mellanox 驱动"
  return 1
}

run_driver_installer() {
  local name="$1"
  local slug="$2"
  local status
  local component_log="${DEBUG_DIR}/${slug}.stdout.log"
  shift 2

  if bool_is_true "${FIRSTBOOT_DEBUG}"; then
    mkdir -p "${DEBUG_DIR}"
    log "开始安装 ${name}，组件日志：${component_log}"
  else
    log "开始安装 ${name}"
  fi

  set +e
  if bool_is_true "${FIRSTBOOT_DEBUG}"; then
    DRIVER_DEBUG_DIR="${DEBUG_DIR}" FIRSTBOOT_DEBUG="${FIRSTBOOT_DEBUG}" DRIVER_OFFLINE_MODE="${DRIVER_OFFLINE_MODE}" MLNX_INSTALL_PROFILE="${MLNX_INSTALL_PROFILE}" \
      "$@" 2>&1 | tee -a "${LOG_FILE}" "${component_log}"
    status=${PIPESTATUS[0]}
  else
    DRIVER_DEBUG_DIR="${DEBUG_DIR}" FIRSTBOOT_DEBUG="${FIRSTBOOT_DEBUG}" DRIVER_OFFLINE_MODE="${DRIVER_OFFLINE_MODE}" MLNX_INSTALL_PROFILE="${MLNX_INSTALL_PROFILE}" \
      "$@" 2>&1 | tee -a "${LOG_FILE}"
    status=${PIPESTATUS[0]}
  fi
  set -e

  if [[ "${status}" -eq 0 ]]; then
    log "${name} 安装完成"
    return 0
  fi

  DRIVER_FAILURES=$((DRIVER_FAILURES + 1))
  printf '[%s] %s failed, exit_code=%s, command=%q\n' \
    "$(date '+%F %T')" "${name}" "${status}" "$*" >> "${FAILURE_FILE}"
  if bool_is_true "${FIRSTBOOT_DEBUG}"; then
    log "${name} 安装失败，退出码 ${status}，详情见 ${component_log}"
  else
    log "${name} 安装失败，退出码 ${status}"
  fi
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

handle_driver_failures() {
  if [[ "${DRIVER_FAILURES}" -eq 0 ]]; then
    return 0
  fi

  log "检测到 ${DRIVER_FAILURES} 个驱动安装失败，失败摘要：${FAILURE_FILE}"
  collect_firstboot_snapshot
  log "驱动安装失败，跳过最终验收、清理和自动重启，保留现场"
  return 1
}

run_final_verification() {
  local status expected_kernel=""

  if ! bool_is_true "${FINAL_VERIFY_ENABLED}"; then
    log "FINAL_VERIFY_ENABLED=false，跳过最终验收脚本"
    return 0
  fi

  if [[ ! -x "${FINAL_VERIFY_SCRIPT}" ]]; then
    {
      printf '[%s] verify_script=%s\n' "$(date '+%F %T')" "${FINAL_VERIFY_SCRIPT}"
      printf '最终验收脚本不存在或不可执行。\n'
    } >> "${VERIFY_FAILURE_FILE}"
    log "最终验收失败：脚本不存在或不可执行：${FINAL_VERIFY_SCRIPT}"
    return 1
  fi

  if [[ -n "${KERNEL_VERSION}" ]]; then
    expected_kernel="$(normalize_kernel_abi "${KERNEL_VERSION}" "${KERNEL_FLAVOR}")"
  fi

  log "开始执行最终验收脚本：${FINAL_VERIFY_SCRIPT}"
  set +e
  EXTRAS_DIR="${EXTRAS_DIR}" \
    STATE_DIR="${STATE_DIR}" \
    FAILURE_FILE="${FAILURE_FILE}" \
    VERIFY_LOG_FILE="${VERIFY_LOG_FILE}" \
    KERNEL_VERSION="${KERNEL_VERSION}" \
    KERNEL_FLAVOR="${KERNEL_FLAVOR}" \
    EXPECTED_KERNEL="${expected_kernel}" \
    "${FINAL_VERIFY_SCRIPT}" 2>&1 | tee -a "${LOG_FILE}"
  status=${PIPESTATUS[0]}
  set -e

  if [[ "${status}" -eq 0 ]]; then
    rm -f "${VERIFY_FAILURE_FILE}"
    log "最终验收通过"
    return 0
  fi

  {
    printf '[%s] verify_script=%s exit_code=%s\n' "$(date '+%F %T')" "${FINAL_VERIFY_SCRIPT}" "${status}"
    printf '最终验收失败，已阻止清理安装残留和自动重启。\n'
  } >> "${VERIFY_FAILURE_FILE}"
  log "最终验收失败，保留 ${EXTRAS_DIR}、iso-firstboot.service 和现场日志，不自动重启"
  return "${status}"
}

mark_firstboot_done() {
  date '+%F %T' > "${DONE_FILE}"
  log "已写入首次开机完成标记：${DONE_FILE}"
}

stop_without_cleanup() {
  local reason="$1"

  collect_firstboot_snapshot
  log "${reason}"
  log "未执行清理，也未请求自动重启"
  exit 1
}

install_drivers() {
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
}

finish_successfully() {
  mark_firstboot_done
  cleanup_firstboot_residue false
  log "===== firstboot.sh 完成 ====="
  request_reboot_if_needed
}

prepare_firstboot() {
  rm -f "${FAILURE_FILE}" "${VERIFY_FAILURE_FILE}"
  log "===== firstboot.sh 开始，当前内核：$(uname -r) ====="
  load_firstboot_config
  load_kernel_config
  enable_debug_trace
  trap 'on_error "${LINENO}" "${BASH_COMMAND}" "$?"' ERR
  collect_firstboot_snapshot
}

main() {
  if [[ -f "${DONE_FILE}" ]]; then
    log "首次开机任务已完成，跳过"
    exit 0
  fi

  prepare_firstboot

  if ! validate_target_kernel_for_drivers; then
    stop_without_cleanup "内核校验失败，已阻止 NVIDIA/Mellanox 驱动安装"
  fi

  install_drivers

  if ! handle_driver_failures; then
    stop_without_cleanup "驱动安装失败，等待现场排查"
  fi

  if ! run_final_verification; then
    stop_without_cleanup "最终验收失败，等待现场排查"
  fi

  finish_successfully
}

main "$@"
