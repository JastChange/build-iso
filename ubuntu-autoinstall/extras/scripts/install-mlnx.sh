#!/usr/bin/env bash
# install-mlnx.sh <MLNX_OFED_LINUX-*.tgz|MLNX_OFED_LINUX-*.iso>
set -euo pipefail

MLNX_PACKAGE="${1:?用法: $0 <MLNX_OFED_LINUX-*.tgz|MLNX_OFED_LINUX-*.iso>}"
LOG="/var/log/mlnx-ofed-install.log"
DEBUG_DIR="${DRIVER_DEBUG_DIR:-/var/log/ubuntu-autoinstall-debug}"
FIRSTBOOT_DEBUG="${FIRSTBOOT_DEBUG:-true}"
DRIVER_OFFLINE_MODE="${DRIVER_OFFLINE_MODE:-true}"
MLNX_INSTALL_PROFILE="${MLNX_INSTALL_PROFILE:-basic}"
TMPDIR=""
MOUNT_DIR=""
OFED_DIR=""
MLNX_INSTALL_ARGS=()

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

  exec {MLNX_TRACE_FD}>>"${DEBUG_DIR}/mlnx-ofed.trace"
  export BASH_XTRACEFD="${MLNX_TRACE_FD}"
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

build_mlnx_install_args() {
  MLNX_INSTALL_ARGS=()

  case "${MLNX_INSTALL_PROFILE}" in
    ""|none|NONE)
      log "Mellanox OFED 安装 profile：none"
      ;;
    basic|hpc|all|dpdk|ovs-dpdk|vma|xlio|guest|hypervisor|bluefield)
      MLNX_INSTALL_ARGS+=("--${MLNX_INSTALL_PROFILE}")
      log "Mellanox OFED 安装 profile：--${MLNX_INSTALL_PROFILE}"
      ;;
    *)
      log "警告：未知 MLNX_INSTALL_PROFILE=${MLNX_INSTALL_PROFILE}，回退到 --basic"
      MLNX_INSTALL_ARGS+=(--basic)
      ;;
  esac

  MLNX_INSTALL_ARGS+=(
    --without-fw-update
    --add-kernel-support
    --skip-distro-check
    --force
    --enable-opensm
    --tmpdir /tmp/ofed-build
  )
}

detect_ofed_target_distro() {
  local filename

  filename="$(basename "${MLNX_PACKAGE}")"
  case "${filename}" in
    *ubuntu24.04*) printf 'ubuntu24.04\n' ;;
    *ubuntu22.04*) printf 'ubuntu22.04\n' ;;
    *ubuntu20.04*) printf 'ubuntu20.04\n' ;;
    *ubuntu18.04*) printf 'ubuntu18.04\n' ;;
    *) printf 'unknown\n' ;;
  esac
}

collect_mlnx_snapshot() {
  local snapshot="${DEBUG_DIR}/mlnx-ofed-system.txt"
  local kernel current_distro target_distro

  kernel="$(uname -r)"
  # shellcheck disable=SC1091
  source /etc/os-release 2>/dev/null || true
  current_distro="ubuntu${VERSION_ID:-unknown}"
  target_distro="$(detect_ofed_target_distro)"

  {
    echo "===== Mellanox OFED snapshot $(date '+%F %T') ====="
    echo "package: ${MLNX_PACKAGE}"
    echo "package_size: $(stat -c '%s' "${MLNX_PACKAGE}" 2>/dev/null || true)"
    echo "package_type: ${MLNX_PACKAGE##*.}"
    echo "install_profile: ${MLNX_INSTALL_PROFILE}"
    echo "driver_offline_mode: ${DRIVER_OFFLINE_MODE}"
    echo "target_distro_from_filename: ${target_distro}"
    echo "current_distro: ${current_distro}"
    if [[ "${target_distro}" != "unknown" && "${target_distro}" != "${current_distro}" ]]; then
      echo "warning: OFED archive distro does not match installed OS"
    fi
    echo
    echo "----- os-release -----"
    cat /etc/os-release 2>/dev/null || true
    echo
    echo "----- kernel -----"
    uname -a
    ls -ld "/lib/modules/${kernel}" "/lib/modules/${kernel}/build" "/usr/src/linux-headers-${kernel}" 2>/dev/null || true
    echo
    echo "----- selected packages -----"
    dpkg-query -W -f='${binary:Package}\t${Version}\t${Status}\n' \
      python3 python3-distutils ethtool lsof tk tcl libglib2.0-0 pciutils \
      numactl libnuma1 dkms build-essential "linux-headers-${kernel}" \
      rdma-core libibverbs1 2>/dev/null || true
    echo
    echo "----- dkms status -----"
    dkms status 2>/dev/null || true
    echo
    echo "----- pci mellanox devices -----"
    lspci -nn 2>/dev/null | grep -Ei 'mellanox|infiniband|ethernet' || true
    echo
    echo "----- modules before install -----"
    lsmod 2>/dev/null | grep -E 'mlx|ib_|rdma' || true
    echo
    echo "----- existing ofed info -----"
    ofed_info -s 2>/dev/null || true
    echo
    echo "----- archive top-level listing -----"
    if [[ "${MLNX_PACKAGE}" == *.tgz ]]; then
      tar tzf "${MLNX_PACKAGE}" 2>/dev/null | head -80 || true
    else
      file "${MLNX_PACKAGE}" 2>/dev/null || true
    fi
    echo
    echo "----- disk usage -----"
    df -h / /var /tmp 2>/dev/null || true
  } >> "${snapshot}" 2>&1

  if [[ "${target_distro}" != "unknown" && "${target_distro}" != "${current_distro}" ]]; then
    log "警告：OFED 包目标系统为 ${target_distro}，当前系统为 ${current_distro}，安装可能失败"
  fi
  log "已写入 Mellanox OFED 调试快照：${snapshot}"
}

collect_mlnx_failure_summary() {
  local artifact_dir="$1"
  local summary="${artifact_dir}/failure-summary.txt"
  local file safe_name

  {
    echo "===== Mellanox OFED failure summary $(date '+%F %T') ====="
    echo "package: ${MLNX_PACKAGE}"
    echo "install_profile: ${MLNX_INSTALL_PROFILE}"
    echo
    echo "----- dpkg --audit -----"
    dpkg --audit 2>&1 || true
    echo
    echo "----- apt-get check -----"
    apt-get check 2>&1 || true
    echo
    echo "----- dpkg rdma/mlnx/ofed packages -----"
    dpkg-query -W -f='${binary:Package}\t${Version}\t${Status}\n' \
      'rdma*' 'libib*' 'mlnx*' 'ofed*' 2>/dev/null || true
    echo
    echo "----- installer logs tail -----"
  } > "${summary}" 2>&1

  if [[ -d /tmp/ofed-build ]]; then
    while IFS= read -r file; do
      safe_name="$(printf '%s' "${file#/tmp/ofed-build/}" | tr '/ ' '__')"
      cp -a "${file}" "${artifact_dir}/${safe_name}" 2>/dev/null || true
      {
        echo
        echo "===== ${file} ====="
        tail -n 200 "${file}" 2>&1 || true
      } >> "${summary}" 2>&1
    done < <(find /tmp/ofed-build -type f \( -name '*.debinstall.log' -o -name 'general.log' -o -name 'mlnx_ofed_iso*.log' -o -name '*.err' -o -name '*.out' \) | sort)
  fi

  log "已生成 Mellanox OFED 失败摘要：${summary}"
}

collect_mlnx_artifacts() {
  local artifact_dir="${DEBUG_DIR}/mlnx-ofed-artifacts"

  mkdir -p "${artifact_dir}"
  cp -a "${LOG}" "${artifact_dir}/" 2>/dev/null || true
  if [[ -n "${TMPDIR}" && -d "${TMPDIR}" ]]; then
    find "${TMPDIR}" -type f \( -name '*.log' -o -name '*.txt' -o -name '*.err' -o -name '*.out' \) \
      -exec cp --parents {} "${artifact_dir}/" \; 2>/dev/null || true
    find "${TMPDIR}" -maxdepth 3 -type f -printf '%p %s bytes\n' > "${artifact_dir}/tmpdir-files.txt" 2>/dev/null || true
  fi
  if [[ -d /tmp/ofed-build ]]; then
    find /tmp/ofed-build -type f \( -name '*.log' -o -name '*.txt' -o -name '*.err' -o -name '*.out' \) \
      -exec cp --parents {} "${artifact_dir}/" \; 2>/dev/null || true
    find /tmp/ofed-build -maxdepth 4 -type f -printf '%p %s bytes\n' > "${artifact_dir}/ofed-build-files.txt" 2>/dev/null || true
  fi
  dmesg > "${artifact_dir}/dmesg.log" 2>/dev/null || true
  dkms status > "${artifact_dir}/dkms-status.txt" 2>/dev/null || true
  ofed_info -s > "${artifact_dir}/ofed-info.txt" 2>/dev/null || true
  collect_mlnx_failure_summary "${artifact_dir}"
  log "已归档 Mellanox OFED 调试文件：${artifact_dir}"
}

on_error() {
  local line="$1"
  local command="$2"
  local status="$3"

  log "错误：Mellanox OFED 安装在第 ${line} 行失败，退出码 ${status}，命令：${command}"
  collect_mlnx_artifacts
}

cleanup() {
  collect_mlnx_artifacts
  if [[ -n "${MOUNT_DIR}" ]]; then
    umount "${MOUNT_DIR}" 2>/dev/null || true
  fi
  rm -rf "${TMPDIR}" /tmp/ofed-build 2>/dev/null || true
}

prepare_ofed_source() {
  TMPDIR="$(mktemp -d)"

  case "${MLNX_PACKAGE}" in
    *.tgz)
      run_logged tar xzf "${MLNX_PACKAGE}" -C "${TMPDIR}"
      OFED_DIR="$(find "${TMPDIR}" -maxdepth 1 -type d -name 'MLNX_OFED*' | head -1)"
      [[ -n "${OFED_DIR}" ]] || { log "错误：未找到 MLNX_OFED 目录"; exit 1; }
      ;;
    *.iso)
      MOUNT_DIR="${TMPDIR}/mlnx-ofed-iso"
      mkdir -p "${MOUNT_DIR}"
      run_logged mount -o loop,ro "${MLNX_PACKAGE}" "${MOUNT_DIR}"
      if [[ -x "${MOUNT_DIR}/mlnxofedinstall" ]]; then
        OFED_DIR="${MOUNT_DIR}"
      else
        OFED_DIR="$(find "${MOUNT_DIR}" -maxdepth 2 -type f -name mlnxofedinstall -printf '%h\n' | head -1)"
      fi
      [[ -n "${OFED_DIR}" ]] || { log "错误：ISO 中未找到 mlnxofedinstall"; exit 1; }
      ;;
    *)
      log "错误：不支持的 Mellanox OFED 包格式：${MLNX_PACKAGE}"
      exit 1
      ;;
  esac

  log "Mellanox OFED 安装目录：${OFED_DIR}"
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

  log "Mellanox OFED 缺失依赖：${missing[*]}"
  if bool_true "${DRIVER_OFFLINE_MODE}"; then
    log "DRIVER_OFFLINE_MODE=true，禁止首次开机阶段联网安装依赖"
    log "请将缺失包加入 ubuntu-autoinstall/extras/config/packages.list 或 extras/repo 后重新构建 ISO"
    return 1
  fi

  log "DRIVER_OFFLINE_MODE=false，尝试联网安装 Mellanox OFED 缺失依赖"
  export DEBIAN_FRONTEND=noninteractive
  run_logged apt-get update
  run_logged apt-get install -y --no-install-recommends "${missing[@]}"
}

mkdir -p "${DEBUG_DIR}"
enable_debug_trace
trap 'on_error "${LINENO}" "${BASH_COMMAND}" "$?"' ERR
trap 'status=$?; cleanup; trap - EXIT; exit "${status}"' EXIT

log "Mellanox OFED 安装包：$(basename "${MLNX_PACKAGE}")"
log "当前运行内核：$(uname -r)"
collect_mlnx_snapshot

ensure_packages \
  python3 python3-distutils ethtool lsof tk tcl libglib2.0-0 pciutils \
  numactl libnuma1 dkms build-essential bison swig flex graphviz gfortran libgfortran5 \
  "linux-headers-$(uname -r)"

prepare_ofed_source

mkdir -p /tmp/ofed-build
build_mlnx_install_args
run_logged "${OFED_DIR}/mlnxofedinstall" "${MLNX_INSTALL_ARGS[@]}"

log "Mellanox OFED 安装完成"
