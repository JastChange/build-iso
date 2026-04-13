#!/bin/bash
# download-kernel.sh — 下载指定版本内核 deb 包（用于离线安装）
# 用法: ./download-kernel.sh <内核版本号>
# 示例: ./download-kernel.sh 5.15.0-105

set -euo pipefail

KERNEL_VERSION="${1:-}"

if [[ -z "${KERNEL_VERSION}" ]]; then
    echo "用法: $0 <内核版本号>"
    echo "示例: $0 5.15.0-105"
    echo ""
    echo "查看可用内核版本:"
    echo "  apt-cache search linux-image-5.15.0 | grep generic"
    exit 1
fi

OUTPUT_DIR="${2:-./kernel-debs}"
mkdir -p "${OUTPUT_DIR}"

echo "========================================"
echo "下载内核版本: ${KERNEL_VERSION}"
echo "输出目录: ${OUTPUT_DIR}"
echo "========================================"
echo ""

# 检查 apt 是否可用
if ! command -v apt &>/dev/null; then
    echo "错误: 需要 apt 命令，请在 Ubuntu/Debian 系统上运行"
    exit 1
fi

cd "${OUTPUT_DIR}"

echo "[1/4] 正在下载 linux-image..."
if apt download "linux-image-${KERNEL_VERSION}-generic" 2>/dev/null; then
    echo "  ✓ linux-image-${KERNEL_VERSION}-generic"
else
    echo "  ✗ linux-image-${KERNEL_VERSION}-generic 下载失败"
    echo "    尝试搜索可用版本:"
    apt-cache search "linux-image-${KERNEL_VERSION%%.*}" | grep generic || true
    exit 1
fi

echo "[2/4] 正在下载 linux-headers..."
if apt download "linux-headers-${KERNEL_VERSION}-generic" 2>/dev/null; then
    echo "  ✓ linux-headers-${KERNEL_VERSION}-generic"
else
    echo "  ! linux-headers 下载失败（非必需，继续）"
fi

echo "[3/4] 正在下载 linux-modules..."
if apt download "linux-modules-${KERNEL_VERSION}-generic" 2>/dev/null; then
    echo "  ✓ linux-modules-${KERNEL_VERSION}-generic"
else
    echo "  ! linux-modules 下载失败（非必需，继续）"
fi

echo "[4/4] 正在下载 linux-modules-extra（可选）..."
if apt download "linux-modules-extra-${KERNEL_VERSION}-generic" 2>/dev/null; then
    echo "  ✓ linux-modules-extra-${KERNEL_VERSION}-generic"
else
    echo "  - linux-modules-extra 不可用（非必需）"
fi

echo ""
echo "========================================"
echo "下载完成！文件列表："
echo "========================================"
ls -lh "${OUTPUT_DIR}"
echo ""
echo "使用方法："
echo "  1. 将下载的 deb 包复制到项目:"
echo "     cp ${OUTPUT_DIR}/*.deb ubuntu-autoinstall/extras/debs/"
echo ""
echo "  2. 构建 ISO:"
echo "     cd ubuntu-autoinstall && sudo bash build.sh"
echo ""
