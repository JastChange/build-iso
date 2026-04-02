#!/bin/bash
# customize-squashfs.sh — 定制 squashfs（预装软件包 + 替换驱动）
# 参数：$1 = ISO 解包工作目录
set -euo pipefail

WORK_DIR="${1:?用法: $0 <ISO工作目录>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SQUASHFS="${WORK_DIR}/casper/filesystem.squashfs"
SQUASHFS_ROOT="/tmp/squashfs-root"
LOG="/tmp/customize-squashfs.log"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
step()  { echo -e "\n${BOLD}${BLUE}──── $* ────${NC}"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
ok()    { echo -e "${GREEN}[OK]${NC}   $*"; }

[[ $EUID -ne 0 ]] && error "需要 root 权限"
[[ -f "${SQUASHFS}" ]] || error "squashfs 不存在：${SQUASHFS}"
command -v unsquashfs &>/dev/null || error "缺少 squashfs-tools"
command -v mksquashfs &>/dev/null || error "缺少 squashfs-tools"

# ──── 第 1 步：解包 squashfs ────
step "解包 squashfs"
rm -rf "${SQUASHFS_ROOT}"
unsquashfs -d "${SQUASHFS_ROOT}" "${SQUASHFS}" 2>&1 | tail -3
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

# 预装包列表（所有需要的软件都在这里，user-data 中不再声明 packages）
PREINSTALL_PACKAGES=(
  # 基础工具
  openssh-server curl wget vim htop net-tools
  # 编译工具链
  build-essential gcc g++ make cmake
  dkms linux-headers-generic
  # Python
  python3 python3-dev
)

chroot "${SQUASHFS_ROOT}" bash -c "
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q
  apt-get install -y -q --no-install-recommends ${PREINSTALL_PACKAGES[*]}
" 2>&1 | tee -a "${LOG}"
ok "预装包安装完成"

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

# ──── 第 6 步：清理缓存 ────
step "清理缓存"
chroot "${SQUASHFS_ROOT}" bash -c "
  apt-get clean
  rm -rf /var/lib/apt/lists/*
  rm -rf /tmp/* /var/tmp/*
"
ok "缓存已清理"

# ──── 第 7 步：卸载 chroot + 重新打包 ────
step "重新打包 squashfs"
cleanup_chroot
trap - EXIT  # 清除 trap，因为已手动调用

rm -f "${SQUASHFS}"
mksquashfs "${SQUASHFS_ROOT}" "${SQUASHFS}" \
  -comp xz -b 1M -Xdict-size 100% \
  -no-progress 2>&1 | tail -3
ok "squashfs 重新打包完成（$(du -sh "${SQUASHFS}" | cut -f1)）"

# 更新 filesystem.size
du -sx --block-size=1 "${SQUASHFS_ROOT}" | cut -f1 > "${WORK_DIR}/casper/filesystem.size"
ok "filesystem.size 已更新"

# 清理解包目录
rm -rf "${SQUASHFS_ROOT}"
ok "squashfs 定制完成"
