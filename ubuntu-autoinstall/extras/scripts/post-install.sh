#!/bin/bash
# post-install.sh
# 由 autoinstall late-commands 通过 curtin in-target 调用
# 运行环境：目标系统内（已 chroot 至 /target）
set -euo pipefail

EXTRAS_DIR="/opt/extras"
LOG_FILE="/var/log/post-install.log"
LOCAL_REPO_DIR="${EXTRAS_DIR}/repo"
LOCAL_REPO_SOURCE="/etc/apt/sources.list.d/local-offline.list"
LOCAL_REPO_KEY="${EXTRAS_DIR}/keys/repo-signing.gpg"
KERNEL_CONFIG_FILE="${EXTRAS_DIR}/config/kernel.env"
DEBS_DIR="${EXTRAS_DIR}/debs"

KERNEL_VERSION=""
KERNEL_FLAVOR="generic"
INSTALL_MODE="auto"
KERNEL_HOLD="true"
USE_LOCAL_REPO=""
HOLD_KERNEL=""

log() { echo "[$(date '+%F %T')] $*" | tee -a "${LOG_FILE}"; }

normalize_kernel_abi() {
  local version="$1"
  local flavor="$2"
  if [[ -z "${version}" ]]; then
    return 1
  fi
  if [[ "${version}" == *"-${flavor}" ]]; then
    echo "${version}"
  else
    echo "${version}-${flavor}"
  fi
}

bool_is_true() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

has_local_repo() {
  [[ -d "${LOCAL_REPO_DIR}" ]] && [[ -f "${LOCAL_REPO_DIR}/Packages" || -f "${LOCAL_REPO_DIR}/Packages.gz" ]]
}

apt_update_with_source() {
  local source_file="$1"
  apt-get \
    -o Dir::Etc::sourcelist="${source_file}" \
    -o Dir::Etc::sourceparts="-" \
    -o APT::Get::List-Cleanup="0" \
    update
}

apt_install_with_source() {
  local source_file="$1"
  shift
  apt-get \
    -o Dir::Etc::sourcelist="${source_file}" \
    -o Dir::Etc::sourceparts="-" \
    -o APT::Get::List-Cleanup="0" \
    install -y --no-install-recommends "$@"
}

apt_fix_with_source() {
  local source_file="$1"
  apt-get \
    -o Dir::Etc::sourcelist="${source_file}" \
    -o Dir::Etc::sourceparts="-" \
    -o APT::Get::List-Cleanup="0" \
    -f install -y
}

apt_cache_has_with_source() {
  local source_file="$1"
  local package_name="$2"
  apt-cache \
    -o Dir::Etc::sourcelist="${source_file}" \
    -o Dir::Etc::sourceparts="-" \
    show "${package_name}" >/dev/null 2>&1
}

configure_local_repo() {
  if ! has_local_repo; then
    return 1
  fi

  log "检测到本地离线仓库：${LOCAL_REPO_DIR}"
  if [[ -f "${LOCAL_REPO_KEY}" ]]; then
    install -m 0644 "${LOCAL_REPO_KEY}" /etc/apt/trusted.gpg.d/repo-signing.gpg
  fi

  cat > "${LOCAL_REPO_SOURCE}" <<EOF
deb [signed-by=/etc/apt/trusted.gpg.d/repo-signing.gpg] file://${LOCAL_REPO_DIR} ./
EOF
  log "本地离线仓库源已写入：${LOCAL_REPO_SOURCE}"
  return 0
}

find_matching_deb() {
  local package_name="$1"
  local matches=()
  shopt -s nullglob
  matches=("${DEBS_DIR}/${package_name}"_*.deb)
  shopt -u nullglob
  if [[ ${#matches[@]} -gt 0 ]]; then
    echo "${matches[0]}"
    return 0
  fi
  return 1
}

install_target_kernel_from_debs() {
  local kernel_abi="$1"
  local kernel_base="${kernel_abi%-${KERNEL_FLAVOR}}"
  local packages=(
    "linux-headers-${kernel_base}"
    "linux-modules-${kernel_abi}"
    "linux-image-${kernel_abi}"
    "linux-headers-${kernel_abi}"
  )
  local optional_package="linux-modules-extra-${kernel_abi}"
  local deb_files=()
  local package_name=""
  local deb_file=""

  if [[ ! -d "${DEBS_DIR}" ]]; then
    log "未发现 deb 目录：${DEBS_DIR}"
    return 1
  fi

  for package_name in "${packages[@]}"; do
    if deb_file="$(find_matching_deb "${package_name}")"; then
      deb_files+=("${deb_file}")
    else
      log "缺少内核 deb 包：${package_name}"
      return 1
    fi
  done

  if deb_file="$(find_matching_deb "${optional_package}")"; then
    deb_files=("${deb_file}" "${deb_files[@]}")
  else
    log "未发现可选包 ${optional_package}，按可选包跳过"
  fi

  log "使用 deb 模式安装内核：${kernel_abi}"
  if ! dpkg -i "${deb_files[@]}"; then
    if configure_local_repo; then
      log "deb 模式检测到本地 repo，使用本地 repo 修复依赖"
      apt_update_with_source "${LOCAL_REPO_SOURCE}"
      apt_fix_with_source "${LOCAL_REPO_SOURCE}"
    else
      log "错误：deb 模式安装存在缺失依赖，且未提供本地 repo。请至少补齐内核相关依赖包（含 common headers 等），或改用 INSTALL_MODE=repo/auto。"
      return 1
    fi
  fi

  return 0
}

install_target_kernel() {
  if [[ -z "${KERNEL_VERSION}" ]]; then
    log "未配置 KERNEL_VERSION，跳过固定内核安装"
    return 0
  fi

  local kernel_abi=""
  kernel_abi="$(normalize_kernel_abi "${KERNEL_VERSION}" "${KERNEL_FLAVOR}")"
  local packages=(
    "linux-image-${kernel_abi}"
    "linux-headers-${kernel_abi}"
    "linux-modules-${kernel_abi}"
  )
  local optional_package="linux-modules-extra-${kernel_abi}"

  case "${INSTALL_MODE}" in
    deb)
      install_target_kernel_from_debs "${kernel_abi}"
      ;;
    repo)
      configure_local_repo || {
        log "错误：INSTALL_MODE=repo，但未找到可用的本地仓库"
        return 1
      }
      log "使用本地离线仓库安装内核：${kernel_abi}"
      apt_update_with_source "${LOCAL_REPO_SOURCE}"
      if apt_cache_has_with_source "${LOCAL_REPO_SOURCE}" "${optional_package}"; then
        packages+=("${optional_package}")
      else
        log "本地仓库中未发现 ${optional_package}，按可选包跳过"
      fi
      apt_install_with_source "${LOCAL_REPO_SOURCE}" "${packages[@]}"
      ;;
    auto)
      if configure_local_repo; then
        log "INSTALL_MODE=auto，优先使用本地离线仓库"
        apt_update_with_source "${LOCAL_REPO_SOURCE}"
        if apt_cache_has_with_source "${LOCAL_REPO_SOURCE}" "${optional_package}"; then
          packages+=("${optional_package}")
        fi
        apt_install_with_source "${LOCAL_REPO_SOURCE}" "${packages[@]}"
      elif install_target_kernel_from_debs "${kernel_abi}"; then
        log "INSTALL_MODE=auto，已回退到 deb 模式"
      else
        log "INSTALL_MODE=auto，本地 repo/deb 均不可用，回退到系统 APT 源"
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        if apt-cache show "${optional_package}" >/dev/null 2>&1; then
          packages+=("${optional_package}")
        else
          log "系统源中未发现 ${optional_package}，按可选包跳过"
        fi
        apt-get install -y --no-install-recommends "${packages[@]}"
      fi
      ;;
    *)
      log "错误：未知 INSTALL_MODE=${INSTALL_MODE}，支持 deb|repo|auto"
      return 1
      ;;
  esac

  if bool_is_true "${KERNEL_HOLD}"; then
    for pkg in "${packages[@]}"; do
      if dpkg -s "${pkg}" >/dev/null 2>&1; then
        apt-mark hold "${pkg}" >/dev/null
        log "已锁定内核包：${pkg}"
      fi
    done
  fi

  update-grub
  log "固定内核安装完成：${kernel_abi}"
}

log "===== post-install.sh 开始 ====="

if [[ -f "${KERNEL_CONFIG_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${KERNEL_CONFIG_FILE}"
  if [[ -z "${INSTALL_MODE}" && -n "${USE_LOCAL_REPO}" ]]; then
    case "${USE_LOCAL_REPO}" in
      true) INSTALL_MODE="repo" ;;
      false) INSTALL_MODE="auto" ;;
      auto) INSTALL_MODE="auto" ;;
    esac
  fi
  if [[ -z "${KERNEL_HOLD}" && -n "${HOLD_KERNEL}" ]]; then
    KERNEL_HOLD="${HOLD_KERNEL}"
  fi
  log "已加载内核配置：${KERNEL_CONFIG_FILE}"
else
  log "未发现内核配置文件，使用默认行为"
fi

# ── Mellanox OFED ──
MLNX_TGZ=$(ls "${EXTRAS_DIR}/drivers"/MLNX_OFED_LINUX-*.tgz 2>/dev/null | head -1 || true)
if [[ -n "${MLNX_TGZ}" ]]; then
  log "发现 Mellanox OFED：$(basename "${MLNX_TGZ}")"
  bash "${EXTRAS_DIR}/scripts/install-mlnx.sh" "${MLNX_TGZ}" 2>&1 | tee -a "${LOG_FILE}"
else
  log "未发现 Mellanox OFED，跳过"
fi

# ── NVIDIA 驱动 ──
NVIDIA_RUN=$(ls "${EXTRAS_DIR}/drivers"/NVIDIA-Linux-x86_64-*.run 2>/dev/null | head -1 || true)
if [[ -n "${NVIDIA_RUN}" ]]; then
  log "发现 NVIDIA 驱动：$(basename "${NVIDIA_RUN}")"
  bash "${EXTRAS_DIR}/scripts/install-nvidia.sh" "${NVIDIA_RUN}" 2>&1 | tee -a "${LOG_FILE}"
else
  log "未发现 NVIDIA 驱动，跳过"
fi

install_target_kernel

# ── 在此追加其他自定义操作 ──
# log "示例：安装 Docker..."
# curl -fsSL https://get.docker.com | sh

log "===== post-install.sh 完成 ====="
