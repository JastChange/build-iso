#!/bin/bash
# build-repo.sh — 构建本地 APT 离线仓库（GPG 签名）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="${SCRIPT_DIR}/extras/repo"
POOL_DIR="${REPO_DIR}/pool"
KEYS_DIR="${SCRIPT_DIR}/extras/keys"
GPG_NAME="ISO Local Repo <repo@local>"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
ok()    { echo -e "${GREEN}[OK]${NC}   $*"; }

# ──── 第 1 步：依赖检查 ────
echo -e "\n\033[1m\033[0;34m──── 依赖检查 ────\033[0m"
for cmd in dpkg-scanpackages apt-ftparchive gpg; do
  if command -v "$cmd" &>/dev/null; then
    ok "$cmd"
  else
    error "缺少工具：$cmd（apt install dpkg-dev apt-utils gnupg）"
  fi
done

# ──── 第 2 步：生成 GPG 密钥（如不存在） ────
echo -e "\n\033[1m\033[0;34m──── GPG 密钥管理 ────\033[0m"
if ! gpg --list-keys "${GPG_NAME}" &>/dev/null; then
  info "生成 GPG 签名密钥..."
  gpg --batch --gen-key <<GPGEOF
Key-Type: RSA
Key-Length: 4096
Name-Real: ISO Local Repo
Name-Email: repo@local
Expire-Date: 0
%no-protection
GPGEOF
  ok "GPG 密钥已生成"
else
  ok "GPG 密钥已存在"
fi

# 导出公钥
mkdir -p "${KEYS_DIR}"
gpg --export --armor "repo@local" > "${KEYS_DIR}/repo-signing.gpg"
ok "公钥已导出到 ${KEYS_DIR}/repo-signing.gpg"

# ──── 第 3 步：下载离线包（可选，需联网） ────
echo -e "\n\033[1m\033[0;34m──── 离线包管理 ────\033[0m"
mkdir -p "${POOL_DIR}"

# 如果 pool/ 中已有 deb 包则跳过下载
DEB_COUNT=$(find "${POOL_DIR}" -name "*.deb" 2>/dev/null | wc -l)
if [[ ${DEB_COUNT} -eq 0 ]]; then
  info "pool/ 为空，尝试下载离线包..."
  # 默认包列表（可根据需要修改）
  OFFLINE_PACKAGES=(
    build-essential gcc g++ make cmake
    dkms linux-headers-generic
    python3 python3-pip python3-dev
    git curl wget htop vim net-tools
    openssh-server
  )

  # 使用 apt-get download 下载包及依赖
  TMPDIR=$(mktemp -d)
  trap "rm -rf ${TMPDIR}" EXIT

  cd "${TMPDIR}"
  for pkg in "${OFFLINE_PACKAGES[@]}"; do
    info "下载 ${pkg} 及依赖..."
    apt-get download $(apt-cache depends --recurse --no-recommends --no-suggests \
      --no-conflicts --no-breaks --no-replaces --no-enhances \
      "${pkg}" 2>/dev/null | grep "^\w" | sort -u) 2>/dev/null || \
      warn "${pkg} 部分依赖下载失败（已存在或架构不匹配）"
  done

  mv *.deb "${POOL_DIR}/" 2>/dev/null || true
  cd "${SCRIPT_DIR}"
  ok "共下载 $(find "${POOL_DIR}" -name "*.deb" | wc -l) 个 deb 包"
else
  ok "pool/ 已有 ${DEB_COUNT} 个 deb 包，跳过下载"
fi

# ──── 第 4 步：生成仓库索引 ────
echo -e "\n\033[1m\033[0;34m──── 生成仓库索引 ────\033[0m"
cd "${REPO_DIR}"
dpkg-scanpackages pool /dev/null 2>/dev/null | gzip -9c > Packages.gz
dpkg-scanpackages pool /dev/null 2>/dev/null > Packages

# 生成 Release 文件
apt-ftparchive release . > Release

# GPG 签名 Release
gpg --default-key "repo@local" --batch --yes -abs -o Release.gpg Release
gpg --default-key "repo@local" --batch --yes --clearsign -o InRelease Release

ok "仓库索引和签名已生成"
echo ""
echo -e "${GREEN}  本地 APT 仓库构建完成！${NC}"
echo "  pool/ 中共 $(find "${POOL_DIR}" -name "*.deb" | wc -l) 个包"
echo "  签名密钥：${KEYS_DIR}/repo-signing.gpg"
echo ""
echo "  目标机配置（已由 late-commands 自动完成）："
echo "    deb [signed-by=/etc/apt/trusted.gpg.d/repo-signing.gpg] file:///opt/extras/repo ./"
