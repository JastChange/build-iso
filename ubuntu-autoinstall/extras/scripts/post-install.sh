#!/usr/bin/env bash
# 由 autoinstall late-commands 通过 curtin in-target 调用。
# 这里运行在目标系统 chroot 内，负责安装固定内核、设置 GRUB 默认内核并注册首次开机任务。
set -euo pipefail

EXTRAS_DIR="${EXTRAS_DIR:-/opt/extras}"
LOG_FILE="${LOG_FILE:-/var/log/post-install.log}"
LOCAL_REPO_DIR="${EXTRAS_DIR}/repo"
LOCAL_REPO_SOURCE="/etc/apt/sources.list.d/ubuntu-autoinstall-local.list"
LOCAL_REPO_KEY_GPG="${EXTRAS_DIR}/keys/repo-signing.gpg"
LOCAL_REPO_KEY_ASC="${EXTRAS_DIR}/keys/repo-signing.asc"
LOCAL_REPO_KEY_DEST="/usr/share/keyrings/ubuntu-autoinstall-local-repo.gpg"
KERNEL_CONFIG_FILE="${EXTRAS_DIR}/config/kernel.env"
DEBS_DIR="${EXTRAS_DIR}/debs"
LIB_FILE="${EXTRAS_DIR}/lib/iso-functions.sh"

KERNEL_VERSION=""
KERNEL_FLAVOR="generic"
INSTALL_MODE="auto"
KERNEL_HOLD="true"
FIRSTBOOT_REBOOT="true"
USE_LOCAL_REPO=""
HOLD_KERNEL=""

mkdir -p "$(dirname "${LOG_FILE}")"

log() {
  echo "[$(date '+%F %T')] $*" | tee -a "${LOG_FILE}"
}

if [[ ! -f "${LIB_FILE}" ]]; then
  log "错误：缺少共享函数库：${LIB_FILE}"
  exit 1
fi
# shellcheck disable=SC1090
source "${LIB_FILE}"

has_local_repo() {
  [[ -d "${LOCAL_REPO_DIR}" ]] &&
    [[ -f "${LOCAL_REPO_DIR}/Packages" || -f "${LOCAL_REPO_DIR}/Packages.gz" ]]
}

configure_local_repo() {
  mkdir -p "$(dirname "${LOCAL_REPO_SOURCE}")" "$(dirname "${LOCAL_REPO_KEY_DEST}")"

  if ! has_local_repo; then
    return 1
  fi

  log "检测到本地离线仓库：${LOCAL_REPO_DIR}"

  if [[ -f "${LOCAL_REPO_KEY_GPG}" ]]; then
    install -m 0644 "${LOCAL_REPO_KEY_GPG}" "${LOCAL_REPO_KEY_DEST}"
    cat > "${LOCAL_REPO_SOURCE}" <<EOF
deb [signed-by=${LOCAL_REPO_KEY_DEST}] file://${LOCAL_REPO_DIR} ./
EOF
  elif [[ -f "${LOCAL_REPO_KEY_ASC}" ]]; then
    install -m 0644 "${LOCAL_REPO_KEY_ASC}" "${LOCAL_REPO_KEY_DEST}"
    cat > "${LOCAL_REPO_SOURCE}" <<EOF
deb [signed-by=${LOCAL_REPO_KEY_DEST}] file://${LOCAL_REPO_DIR} ./
EOF
  else
    log "未发现本地仓库签名公钥，使用 trusted=yes 挂载本地 file 仓库"
    cat > "${LOCAL_REPO_SOURCE}" <<EOF
deb [trusted=yes] file://${LOCAL_REPO_DIR} ./
EOF
  fi

  log "本地离线仓库源已写入：${LOCAL_REPO_SOURCE}"
  return 0
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
  DEBIAN_FRONTEND=noninteractive apt-get \
    -o Dir::Etc::sourcelist="${source_file}" \
    -o Dir::Etc::sourceparts="-" \
    -o APT::Get::List-Cleanup="0" \
    install -y --no-install-recommends "$@"
}

apt_fix_with_source() {
  local source_file="$1"
  DEBIAN_FRONTEND=noninteractive apt-get \
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

find_matching_deb() {
  local package_name="$1"
  local matches=()

  shopt -s nullglob
  matches=("${DEBS_DIR}/${package_name}"_*.deb)
  shopt -u nullglob

  if [[ "${#matches[@]}" -gt 0 ]]; then
    printf '%s\n' "${matches[0]}"
    return 0
  fi
  return 1
}

install_target_kernel_from_debs() {
  local kernel_abi="$1"
  local package_name deb_file
  local deb_files=()
  local required_packages=()
  local optional_packages=()

  if [[ ! -d "${DEBS_DIR}" ]]; then
    log "未发现 deb 目录：${DEBS_DIR}"
    return 1
  fi

  mapfile -t required_packages < <(kernel_required_packages "${kernel_abi}" "${KERNEL_FLAVOR}")
  mapfile -t optional_packages < <(kernel_optional_packages "${kernel_abi}" "${KERNEL_FLAVOR}")

  for package_name in "${required_packages[@]}"; do
    if deb_file="$(find_matching_deb "${package_name}")"; then
      deb_files+=("${deb_file}")
    else
      log "缺少内核 deb 包：${package_name}"
      return 1
    fi
  done

  for package_name in "${optional_packages[@]}"; do
    if deb_file="$(find_matching_deb "${package_name}")"; then
      deb_files+=("${deb_file}")
    else
      log "未发现可选包 ${package_name}，跳过"
    fi
  done

  log "使用 deb 模式安装内核：${kernel_abi}"
  if dpkg -i "${deb_files[@]}"; then
    return 0
  fi

  if configure_local_repo; then
    log "deb 模式安装存在依赖缺口，使用本地 repo 修复依赖"
    apt_update_with_source "${LOCAL_REPO_SOURCE}"
    apt_fix_with_source "${LOCAL_REPO_SOURCE}"
    return 0
  fi

  log "错误：deb 模式缺少依赖且没有可用本地 repo"
  return 1
}

install_target_kernel_from_repo() {
  local kernel_abi="$1"
  local package_name
  local packages=()

  configure_local_repo || {
    log "未找到可用本地仓库"
    return 1
  }

  mapfile -t packages < <(kernel_required_packages "${kernel_abi}" "${KERNEL_FLAVOR}")
  apt_update_with_source "${LOCAL_REPO_SOURCE}"

  while IFS= read -r package_name; do
    if apt_cache_has_with_source "${LOCAL_REPO_SOURCE}" "${package_name}"; then
      packages+=("${package_name}")
    else
      log "本地仓库中未发现可选包 ${package_name}，跳过"
    fi
  done < <(kernel_optional_packages "${kernel_abi}" "${KERNEL_FLAVOR}")

  log "使用本地离线仓库安装内核：${kernel_abi}"
  apt_install_with_source "${LOCAL_REPO_SOURCE}" "${packages[@]}"
}

install_target_kernel_from_system_apt() {
  local kernel_abi="$1"
  local package_name
  local packages=()

  mapfile -t packages < <(kernel_required_packages "${kernel_abi}" "${KERNEL_FLAVOR}")

  log "使用系统 APT 源安装内核：${kernel_abi}"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update

  while IFS= read -r package_name; do
    if apt-cache show "${package_name}" >/dev/null 2>&1; then
      packages+=("${package_name}")
    else
      log "系统源中未发现可选包 ${package_name}，跳过"
    fi
  done < <(kernel_optional_packages "${kernel_abi}" "${KERNEL_FLAVOR}")

  apt-get install -y --no-install-recommends "${packages[@]}"
}

hold_installed_kernel_packages() {
  local kernel_abi="$1"
  local package_name

  if ! bool_is_true "${KERNEL_HOLD}"; then
    log "KERNEL_HOLD=false，不锁定内核包"
    return 0
  fi

  {
    kernel_required_packages "${kernel_abi}" "${KERNEL_FLAVOR}"
    kernel_optional_packages "${kernel_abi}" "${KERNEL_FLAVOR}"
  } | while IFS= read -r package_name; do
    if dpkg -s "${package_name}" >/dev/null 2>&1; then
      apt-mark hold "${package_name}" >/dev/null
      log "已锁定内核包：${package_name}"
    fi
  done
}

set_grub_default_kernel() {
  local kernel_abi="$1"
  local grub_default='Advanced options for Ubuntu>Ubuntu, with Linux '"${kernel_abi}"

  if [[ ! -e "/boot/vmlinuz-${kernel_abi}" ]]; then
    log "错误：未找到 /boot/vmlinuz-${kernel_abi}，不能设置 GRUB 默认内核"
    return 1
  fi

  if grep -q '^GRUB_DEFAULT=' /etc/default/grub 2>/dev/null; then
    sed -i 's|^GRUB_DEFAULT=.*|GRUB_DEFAULT="'"${grub_default}"'"|' /etc/default/grub
  else
    printf 'GRUB_DEFAULT="%s"\n' "${grub_default}" >> /etc/default/grub
  fi

  if command -v grub-set-default >/dev/null 2>&1; then
    grub-set-default "${grub_default}" >/dev/null 2>&1 || true
  fi

  update-grub
  log "已设置 GRUB 默认启动内核：${grub_default}"
}

install_target_kernel() {
  local kernel_abi=""

  if [[ -z "${KERNEL_VERSION}" ]]; then
    log "未配置 KERNEL_VERSION，跳过固定内核安装"
    return 0
  fi

  kernel_abi="$(normalize_kernel_abi "${KERNEL_VERSION}" "${KERNEL_FLAVOR}")"

  case "${INSTALL_MODE}" in
    repo)
      install_target_kernel_from_repo "${kernel_abi}"
      ;;
    deb)
      install_target_kernel_from_debs "${kernel_abi}"
      ;;
    auto)
      if install_target_kernel_from_repo "${kernel_abi}"; then
        log "INSTALL_MODE=auto，已使用本地 repo"
      elif install_target_kernel_from_debs "${kernel_abi}"; then
        log "INSTALL_MODE=auto，已回退到 deb 模式"
      else
        log "INSTALL_MODE=auto，本地 repo/deb 不可用，回退到系统 APT 源"
        install_target_kernel_from_system_apt "${kernel_abi}"
      fi
      ;;
    *)
      log "错误：未知 INSTALL_MODE=${INSTALL_MODE}，支持 deb|repo|auto"
      return 1
      ;;
  esac

  hold_installed_kernel_packages "${kernel_abi}"
  set_grub_default_kernel "${kernel_abi}"
  log "固定内核安装和 GRUB 配置完成：${kernel_abi}"
}

load_kernel_config() {
  if [[ -f "${KERNEL_CONFIG_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${KERNEL_CONFIG_FILE}"
    log "已加载内核配置：${KERNEL_CONFIG_FILE}"
  else
    log "未发现内核配置文件，使用默认行为"
  fi

  if [[ -z "${INSTALL_MODE}" && -n "${USE_LOCAL_REPO}" ]]; then
    case "${USE_LOCAL_REPO}" in
      true) INSTALL_MODE="repo" ;;
      false|auto) INSTALL_MODE="auto" ;;
    esac
  fi

  if [[ -z "${KERNEL_HOLD}" && -n "${HOLD_KERNEL}" ]]; then
    KERNEL_HOLD="${HOLD_KERNEL}"
  fi
}

register_firstboot() {
  chmod +x "${EXTRAS_DIR}/scripts/"*.sh 2>/dev/null || true
  register_firstboot_service "/" "${EXTRAS_DIR}" "${FIRSTBOOT_REBOOT}"
  log "已注册首次开机任务：iso-firstboot.service"
}

main() {
  log "===== post-install.sh 开始 ====="
  load_kernel_config
  install_target_kernel
  register_firstboot
  apt-get clean || true
  log "===== post-install.sh 完成 ====="
}

main "$@"
