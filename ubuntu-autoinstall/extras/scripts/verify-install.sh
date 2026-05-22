#!/usr/bin/env bash
# firstboot 最终验收脚本。只有本脚本返回 0，firstboot 才会清理残留并重启。
set -euo pipefail

EXTRAS_DIR="${EXTRAS_DIR:-/opt/extras}"
STATE_DIR="${STATE_DIR:-/var/lib/ubuntu-autoinstall}"
FAILURE_FILE="${FAILURE_FILE:-${STATE_DIR}/driver-failures.log}"
VERIFY_LOG_FILE="${VERIFY_LOG_FILE:-/var/log/ubuntu-autoinstall-verify.log}"
KERNEL_VERSION="${KERNEL_VERSION:-}"
KERNEL_FLAVOR="${KERNEL_FLAVOR:-generic}"
EXPECTED_KERNEL="${EXPECTED_KERNEL:-}"
DRIVERS_DIR="${EXTRAS_DIR}/drivers"
PACKAGES_LIST="${EXTRAS_DIR}/config/packages.list"
LIB_FILE="${EXTRAS_DIR}/lib/iso-functions.sh"

failures=0

mkdir -p "$(dirname "${VERIFY_LOG_FILE}")" "${STATE_DIR}"

log() {
  echo "[$(date '+%F %T')] $*" | tee -a "${VERIFY_LOG_FILE}"
}

if [[ -f "${LIB_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${LIB_FILE}"
else
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
fi

record_failure() {
  failures=$((failures + 1))
  log "FAIL: $*"
}

record_pass() {
  log "PASS: $*"
}

has_driver_file() {
  local pattern="$1"
  find "${DRIVERS_DIR}" -maxdepth 1 -type f -name "${pattern}" 2>/dev/null | grep -q .
}

run_required_command() {
  local description="$1"
  shift
  local output status

  set +e
  output="$("$@" 2>&1)"
  status=$?
  set -e

  if [[ "${status}" -eq 0 ]]; then
    record_pass "${description}"
    if [[ -n "${output}" ]]; then
      printf '%s\n' "${output}" | sed 's/^/  /' | tee -a "${VERIFY_LOG_FILE}" >/dev/null
    fi
    return 0
  fi

  record_failure "${description}，退出码 ${status}"
  if [[ -n "${output}" ]]; then
    printf '%s\n' "${output}" | sed 's/^/  /' | tee -a "${VERIFY_LOG_FILE}" >/dev/null
  fi
  return 1
}

check_command_exists() {
  local command_name="$1"
  local description="$2"

  if command -v "${command_name}" >/dev/null 2>&1; then
    record_pass "${description}"
  else
    record_failure "${description}：未找到命令 ${command_name}"
  fi
}

check_kernel() {
  local current_kernel

  if [[ -z "${EXPECTED_KERNEL}" && -n "${KERNEL_VERSION}" ]]; then
    EXPECTED_KERNEL="$(normalize_kernel_abi "${KERNEL_VERSION}" "${KERNEL_FLAVOR}")"
  fi

  if [[ -z "${EXPECTED_KERNEL}" ]]; then
    record_pass "未配置目标内核，跳过内核版本验收"
    return 0
  fi

  current_kernel="$(uname -r)"
  if [[ "${current_kernel}" == "${EXPECTED_KERNEL}" ]]; then
    record_pass "当前内核符合目标内核：${current_kernel}"
  else
    record_failure "当前内核 ${current_kernel} 不等于目标内核 ${EXPECTED_KERNEL}"
  fi
}

check_no_driver_failures() {
  if [[ -s "${FAILURE_FILE}" ]]; then
    record_failure "存在驱动失败摘要：${FAILURE_FILE}"
    sed 's/^/  /' "${FAILURE_FILE}" | tee -a "${VERIFY_LOG_FILE}" >/dev/null
  else
    record_pass "未发现驱动失败摘要"
  fi
}

check_packages_list() {
  local package_name line status

  if [[ ! -f "${PACKAGES_LIST}" ]]; then
    record_pass "未找到 packages.list，跳过预装包验收"
    return 0
  fi

  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%%#*}"
    package_name="${line//[[:space:]]/}"
    [[ -n "${package_name}" ]] || continue

    status="$(dpkg-query -W -f='${Status}' "${package_name}" 2>/dev/null || true)"
    if [[ "${status}" == "install ok installed" ]]; then
      record_pass "预装包已安装：${package_name}"
    else
      record_failure "预装包未安装：${package_name}"
    fi
  done < "${PACKAGES_LIST}"
}

check_mellanox() {
  if ! has_driver_file 'MLNX_OFED_LINUX-*'; then
    record_pass "未随 ISO 提供 Mellanox OFED，跳过 Mellanox 验收"
    return 0
  fi

  check_command_exists ofed_info "Mellanox OFED ofed_info 命令可用"
  run_required_command "Mellanox OFED 版本可读取" ofed_info -s || true

  for package_name in ofed-scripts mlnx-tools mlnx-ofed-kernel-modules rdma-core libibverbs1 opensm; do
    if dpkg-query -W -f='${Status}' "${package_name}" 2>/dev/null | grep -q 'install ok installed'; then
      record_pass "Mellanox 包已安装：${package_name}"
    else
      record_failure "Mellanox 包未安装：${package_name}"
    fi
  done

  if systemctl list-unit-files openibd.service --no-legend 2>/dev/null | grep -q '^openibd.service'; then
    record_pass "openibd.service 已注册"
  else
    record_failure "openibd.service 未注册"
  fi

  if systemctl list-unit-files opensmd.service --no-legend 2>/dev/null | grep -q '^opensmd.service'; then
    record_pass "opensmd.service 已注册"
  else
    record_failure "opensmd.service 未注册"
  fi

  if systemctl is-enabled opensmd.service >/dev/null 2>&1; then
    record_pass "opensmd.service 已启用"
  else
    record_failure "opensmd.service 未启用"
  fi
}

check_nvidia() {
  local current_kernel

  if ! has_driver_file 'NVIDIA-Linux-x86_64-*.run'; then
    record_pass "未随 ISO 提供 NVIDIA 驱动，跳过 NVIDIA 验收"
    return 0
  fi

  current_kernel="$(uname -r)"
  check_command_exists nvidia-smi "nvidia-smi 命令可用"
  run_required_command "nvidia-smi 可正常执行" nvidia-smi || true

  if command -v dkms >/dev/null 2>&1; then
    if dkms status 2>/dev/null | grep -Eq "nvidia/.+, ${current_kernel}, .*: installed"; then
      record_pass "NVIDIA DKMS 模块已安装到当前内核：${current_kernel}"
    else
      record_failure "NVIDIA DKMS 模块未安装到当前内核：${current_kernel}"
      dkms status 2>/dev/null | sed 's/^/  /' | tee -a "${VERIFY_LOG_FILE}" >/dev/null || true
    fi
  else
    record_failure "未找到 dkms 命令，无法验收 NVIDIA DKMS 状态"
  fi
}

main() {
  : > "${VERIFY_LOG_FILE}"
  log "===== 最终安装验收开始 ====="
  check_kernel
  check_no_driver_failures
  check_command_exists ipmitool "ipmitool 工具可用"
  check_packages_list
  check_mellanox
  check_nvidia

  if [[ "${failures}" -gt 0 ]]; then
    log "===== 最终安装验收失败：${failures} 项失败 ====="
    exit 1
  fi

  log "===== 最终安装验收通过 ====="
}

main "$@"
