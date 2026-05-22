#!/bin/bash
# customize-squashfs.sh — 定制 squashfs（预装软件包 + 驱动依赖）
# 参数：$1 = ISO 解包工作目录
set -euo pipefail

WORK_DIR="${1:?用法: $0 <ISO工作目录>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CASPER_DIR="${WORK_DIR}/casper"
SQUASHFS_ROOT="/tmp/squashfs-root"
LOG="/tmp/customize-squashfs.log"

# Ubuntu 22.04.5 使用分层 squashfs，定制完整服务器层
SQUASHFS_BASE="${CASPER_DIR}/ubuntu-server-minimal.squashfs"
SQUASHFS_SERVER="${CASPER_DIR}/ubuntu-server-minimal.ubuntu-server.squashfs"
# 兼容旧版 ISO（单文件 filesystem.squashfs）
SQUASHFS_LEGACY="${CASPER_DIR}/filesystem.squashfs"
PACKAGES_FILE="${SCRIPT_DIR}/extras/config/packages.list"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
step()  { echo -e "\n${BOLD}${BLUE}──── $* ────${NC}"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
ok()    { echo -e "${GREEN}[OK]${NC}   $*"; }

# 自动检测 squashfs 路径
if [[ -f "${SQUASHFS_SERVER}" ]]; then
  SQUASHFS="${SQUASHFS_SERVER}"
  SQUASHFS_IS_LAYERED=true
elif [[ -f "${SQUASHFS_LEGACY}" ]]; then
  SQUASHFS="${SQUASHFS_LEGACY}"
  SQUASHFS_IS_LAYERED=false
else
  echo "casper/ 内容：" >&2
  ls -la "${CASPER_DIR}/" >&2
  error "未找到可用的 squashfs 文件"
fi

[[ $EUID -ne 0 ]] && error "需要 root 权限"
command -v unsquashfs &>/dev/null || error "缺少 squashfs-tools"
command -v mksquashfs &>/dev/null || error "缺少 squashfs-tools"

# ──── 扫描 extras/drivers 驱动文件 ────
DRIVERS_DIR="${SCRIPT_DIR}/extras/drivers"
MLNX_PACKAGE="$(find "${DRIVERS_DIR}" -maxdepth 1 -type f \( -name 'MLNX_OFED_LINUX-*.tgz' -o -name 'MLNX_OFED_LINUX-*.iso' \) 2>/dev/null | sort | head -1 || true)"
NVIDIA_RUN="$(ls "${DRIVERS_DIR}"/NVIDIA-Linux-x86_64-*.run 2>/dev/null | head -1 || true)"

step "扫描驱动文件"
if [[ -n "${MLNX_PACKAGE}" ]]; then
  MLNX_BASENAME="$(basename "${MLNX_PACKAGE}")"
  ok "Mellanox OFED : ${MLNX_BASENAME}"
else
  info "未发现 Mellanox OFED（可选）"
fi
if [[ -n "${NVIDIA_RUN}" ]]; then
  NVIDIA_BASENAME="$(basename "${NVIDIA_RUN}")"
  ok "NVIDIA 驱动   : ${NVIDIA_BASENAME}"
else
  info "未发现 NVIDIA 驱动（可选）"
fi

# ──── 第 1 步：解包 squashfs ────
step "解包 squashfs"
rm -rf "${SQUASHFS_ROOT}"

if [[ "${SQUASHFS_IS_LAYERED}" == true ]]; then
  info "分层模式：先解包 base，再叠加 server 层"
  unsquashfs -d "${SQUASHFS_ROOT}" "${SQUASHFS_BASE}" 2>&1 | tail -5 || true
  ok "base 层解包完成"
  # -f 叠加覆盖文件时 unsquashfs 可能返回非零，属于正常行为
  unsquashfs -f -d "${SQUASHFS_ROOT}" "${SQUASHFS_SERVER}" 2>&1 | tail -5 || true
  ok "server 层叠加完成"
else
  info "单文件模式"
  unsquashfs -d "${SQUASHFS_ROOT}" "${SQUASHFS}" 2>&1 | tail -5 || true
fi
# 验证解包结果
[[ -d "${SQUASHFS_ROOT}/usr" ]] || error "squashfs 解包失败：${SQUASHFS_ROOT}/usr 不存在"
ok "解包完成（$(du -sh "${SQUASHFS_ROOT}" | cut -f1)）"

# ──── 第 2 步：准备 chroot 环境 ────
step "准备 chroot 环境"
cleanup_chroot() {
  info "清理 chroot 挂载点..."
  umount -lf "${SQUASHFS_ROOT}/dev/pts"  2>/dev/null || true
  umount -lf "${SQUASHFS_ROOT}/dev"      2>/dev/null || true
  umount -lf "${SQUASHFS_ROOT}/proc"     2>/dev/null || true
  umount -lf "${SQUASHFS_ROOT}/sys"      2>/dev/null || true
  umount -lf "${SQUASHFS_ROOT}/run"      2>/dev/null || true
}
trap cleanup_chroot EXIT

mount --bind /dev     "${SQUASHFS_ROOT}/dev"
mount --bind /dev/pts "${SQUASHFS_ROOT}/dev/pts"
mount --bind /proc    "${SQUASHFS_ROOT}/proc"
mount --bind /sys     "${SQUASHFS_ROOT}/sys"
mount --bind /run     "${SQUASHFS_ROOT}/run"
cp /etc/resolv.conf "${SQUASHFS_ROOT}/etc/resolv.conf" 2>/dev/null || true
ok "chroot 环境就绪"

# ──── 第 3 步：导入 GPG 公钥（自定义仓库时启用） ────
if [[ -f "${SCRIPT_DIR}/extras/keys/repo-signing.gpg" ]]; then
  step "导入 GPG 公钥"
  cp "${SCRIPT_DIR}/extras/keys/repo-signing.gpg" \
     "${SQUASHFS_ROOT}/etc/apt/trusted.gpg.d/repo-signing.gpg"
  ok "GPG 公钥已导入"
fi

# ──── 第 4 步：chroot 安装预装包 ────
step "安装预装软件包"

DEFAULT_PREINSTALL_PACKAGES=(
  openssh-server curl wget vim htop net-tools
  build-essential gcc g++ make cmake
  dkms linux-headers-generic
  python3 python3-dev python3-distutils
  ethtool lsof pciutils numactl libnuma-dev
  tk tcl libglib2.0-0 libfuse2
  libibverbs-dev librdmacm-dev rdma-core
  pkg-config libglvnd-dev
  kmod initramfs-tools
)

read_package_list() {
  local package_file="$1"
  sed -e 's/#.*$//' -e '/^[[:space:]]*$/d' "${package_file}" | awk '{print $1}'
}

if [[ -f "${PACKAGES_FILE}" ]]; then
  mapfile -t PREINSTALL_PACKAGES < <(read_package_list "${PACKAGES_FILE}")
  ok "读取预装包配置：${PACKAGES_FILE}（${#PREINSTALL_PACKAGES[@]} 个）"
else
  PREINSTALL_PACKAGES=("${DEFAULT_PREINSTALL_PACKAGES[@]}")
  warn "未发现 ${PACKAGES_FILE}，使用内置默认预装包"
fi

if [[ "${#PREINSTALL_PACKAGES[@]}" -gt 0 ]]; then
  info "预装包：${PREINSTALL_PACKAGES[*]}"
  chroot "${SQUASHFS_ROOT}" bash -c "
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -q
    apt-get install -y -q --no-install-recommends ${PREINSTALL_PACKAGES[*]}
  " 2>&1 | tee -a "${LOG}"
  ok "预装包安装完成"
else
  warn "预装包列表为空，跳过 apt 安装"
fi

# ──── 第 5 步：替换特定版本 deb 包 ────
step "替换特定版本 deb 包"
DEBS_DIR="${SCRIPT_DIR}/extras/debs"
DEB_FILES=$(find "${DEBS_DIR}" -name "*.deb" 2>/dev/null || true)
if [[ -n "${DEB_FILES}" ]]; then
  cp "${DEBS_DIR}"/*.deb "${SQUASHFS_ROOT}/tmp/"
  chroot "${SQUASHFS_ROOT}" bash -c "
    export DEBIAN_FRONTEND=noninteractive
    dpkg -i /tmp/*.deb || apt-get -f install -y
    rm -f /tmp/*.deb
  " 2>&1 | tee -a "${LOG}"
  ok "特定版本包替换完成"
else
  info "extras/debs/ 为空，跳过"
fi

# ──── 第 6 步：驱动安装策略 ────
step "驱动安装策略"
info "驱动包不在 squashfs 构建阶段安装，会随 extras 注入 ISO"
info "目标系统首次开机后由 /opt/extras/scripts/firstboot.sh 在真实内核下安装驱动"

# ──── 第 7 步：清理缓存 ────
step "清理缓存"
chroot "${SQUASHFS_ROOT}" bash -c "
  apt-get clean
  rm -rf /var/lib/apt/lists/*
  rm -rf /tmp/* /var/tmp/*
  rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub
  truncate -s 0 /etc/machine-id 2>/dev/null || true
  rm -f /var/lib/dbus/machine-id
"
ok "缓存已清理"

# ──── 第 8 步：卸载 chroot + 重新打包 ────
step "重新打包 squashfs"
cleanup_chroot
trap - EXIT  # 清除 trap，因为已手动调用

if [[ "${SQUASHFS_IS_LAYERED}" == true ]]; then
  # 分层模式：initrd live-server 脚本硬编码挂载三类 squashfs：
  #   1. ubuntu-server-minimal.squashfs              → /media/minimal（base 层）
  #   2. ubuntu-server-minimal.ubuntu-server.squashfs → /media/full（server 层）
  #   3. *.installer.*.squashfs                       → LAYERFS_PATH（installer 层）
  # 策略：只替换 server 层（base + server 合并内容），其余全部保留原样
  info "仅替换 server 层：${SQUASHFS_SERVER}"

  # 只删除 server 层的 squashfs 和签名
  rm -f "${SQUASHFS_SERVER}" "${SQUASHFS_SERVER}.gpg"

  # 将合并后的内容重新打包为 server 层
  mksquashfs "${SQUASHFS_ROOT}" "${SQUASHFS_SERVER}" \
    -comp xz -b 1M -Xdict-size 100% \
    -no-progress 2>&1 | tail -3
  ok "server 层重新打包完成（$(du -sh "${SQUASHFS_SERVER}" | cut -f1)）"

  # 更新 server 层的 size 文件
  du -sx --block-size=1 "${SQUASHFS_ROOT}" | cut -f1 > "${CASPER_DIR}/ubuntu-server-minimal.ubuntu-server.size"

  # base 层、installer 层、install-sources.yaml 全部保持原样不动
  ok "base 层保留原样（$(du -sh "${SQUASHFS_BASE}" | cut -f1)）"
  ok "installer 层保留原样"
  ok "install-sources.yaml 保留原样"
else
  # 单文件模式
  rm -f "${SQUASHFS}"
  mksquashfs "${SQUASHFS_ROOT}" "${SQUASHFS}" \
    -comp xz -b 1M -Xdict-size 100% \
    -no-progress 2>&1 | tail -3
  ok "squashfs 重新打包完成（$(du -sh "${SQUASHFS}" | cut -f1)）"
  du -sx --block-size=1 "${SQUASHFS_ROOT}" | cut -f1 > "${WORK_DIR}/casper/filesystem.size"
  ok "filesystem.size 已更新"
fi

# 清理解包目录
rm -rf "${SQUASHFS_ROOT}"

# 最终验证：列出 casper/ 所有 squashfs 文件
step "验证 casper/ 最终状态"
info "casper/ squashfs 文件："
ls -lhS "${CASPER_DIR}"/*.squashfs 2>/dev/null | awk '{printf "  %s (%s)\n", $NF, $5}'
[[ -f "${SQUASHFS_BASE}" ]] && ok "base 层存在" || error "base 层丢失！"
[[ -f "${SQUASHFS_SERVER}" ]] && ok "server 层存在" || error "server 层丢失！"
ok "squashfs 定制完成"
