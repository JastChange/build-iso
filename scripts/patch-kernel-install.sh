#!/bin/bash
# patch-kernel-install.sh — 为 customize-squashfs.sh 添加内核安装步骤
# 用法: ./patch-kernel-install.sh <内核版本号>
# 示例: ./patch-kernel-install.sh 5.15.0-105

set -euo pipefail

KERNEL_VERSION="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CUSTOMIZE_SCRIPT="${SCRIPT_DIR}/../ubuntu-autoinstall/customize-squashfs.sh"

if [[ -z "${KERNEL_VERSION}" ]]; then
    echo "用法: $0 <内核版本号>"
    echo "示例: $0 5.15.0-105"
    exit 1
fi

if [[ ! -f "${CUSTOMIZE_SCRIPT}" ]]; then
    echo "错误: 找不到 customize-squashfs.sh"
    echo "请确保在 build-iso 项目目录下运行此脚本"
    exit 1
fi

echo "========================================"
echo "为 customize-squashfs.sh 添加内核安装"
echo "内核版本: ${KERNEL_VERSION}"
echo "========================================"
echo ""

# 创建补丁内容
PATCH_CONTENT="
# ──── 内核安装步骤（由 patch-kernel-install.sh 添加）────
step \"安装指定版本内核: ${KERNEL_VERSION}\"

# 检查 extras/debs/ 中是否有内核 deb 包
KERNEL_DEBS=\\\$(ls \"\\${SCRIPT_DIR}/extras/debs/\"linux-image-*"${KERNEL_VERSION}"*.deb 2>/dev/null || true)

if [[ -n \"\\\${KERNEL_DEBS}\" ]]; then
    info \"发现离线内核包，使用本地安装\"
    cp \"\\${SCRIPT_DIR}/extras/debs/\"linux-*"${KERNEL_VERSION}"*.deb \"\\${SQUASHFS_ROOT}/tmp/\"
    
    chroot \"\\${SQUASHFS_ROOT}\" bash -c \"
        export DEBIAN_FRONTEND=noninteractive
        cd /tmp
        # 按顺序安装: modules -> image -> headers
        dpkg -i linux-modules-${KERNEL_VERSION}-generic_*.deb || true
        dpkg -i linux-image-${KERNEL_VERSION}-generic_*.deb || true
        dpkg -i linux-headers-${KERNEL_VERSION}-generic_*.deb || true
        # 修复依赖
        apt-get -f install -y || true
        # 更新 grub
        update-grub
    \" 2>&1 | tee -a \"\\${LOG}\"
else
    info \"未找到离线内核包，尝试在线安装\"
    chroot \"\\${SQUASHFS_ROOT}\" bash -c \"
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -q
        apt-get install -y -q \\
            linux-image-${KERNEL_VERSION}-generic \\
            linux-headers-${KERNEL_VERSION}-generic \\
            linux-modules-${KERNEL_VERSION}-generic
    \" 2>&1 | tee -a \"\\${LOG}\"
fi

# 验证内核安装
chroot \"\\${SQUASHFS_ROOT}\" bash -c \"
    echo '[INFO] 已安装的内核版本:'
    ls -la /boot/vmlinuz-*
    echo '[INFO] 内核包详情:'
    dpkg -l | grep linux-image | head -5
\" 2>&1 | tee -a \"\\${LOG}\"

ok \"内核 ${KERNEL_VERSION} 安装完成\"
# ──── 内核安装步骤结束 ────
"

# 检查是否已存在内核安装步骤
if grep -q "安装指定版本内核" "${CUSTOMIZE_SCRIPT}"; then
    echo "警告: customize-squashfs.sh 中已存在内核安装步骤"
    echo "请先手动删除旧的内核安装代码，再运行此脚本"
    exit 1
fi

# 在第 5 步（替换特定版本 deb 包）之后插入内核安装步骤
# 找到 "ok "特定版本包替换完成"" 这一行的行号
TARGET_LINE=$(grep -n 'ok "特定版本包替换完成"' "${CUSTOMIZE_SCRIPT}" | head -1 | cut -d: -f1)

if [[ -z "${TARGET_LINE}" ]]; then
    # 如果没找到中文，尝试英文
    TARGET_LINE=$(grep -n 'ok "Custom package replacement complete"' "${CUSTOMIZE_SCRIPT}" | head -1 | cut -d: -f1)
fi

if [[ -z "${TARGET_LINE}" ]]; then
    echo "警告: 无法找到插入点（'特定版本包替换完成'）"
    echo "将尝试在第 5 步之后插入"
    # 查找 "第 5 步" 或 "step 5"
    TARGET_LINE=$(grep -n -E '(第 5 步|Step 5)' "${CUSTOMIZE_SCRIPT}" | head -1 | cut -d: -f1)
    if [[ -n "${TARGET_LINE}" ]]; then
        # 在步骤开始后约 15 行插入（跳过整个步骤）
        TARGET_LINE=$((TARGET_LINE + 15))
    else
        # 默认在第 140 行插入（大约在第 5 步之后）
        TARGET_LINE=140
    fi
fi

echo "将在第 ${TARGET_LINE} 行后插入内核安装步骤"
echo ""

# 创建备份
cp "${CUSTOMIZE_SCRIPT}" "${CUSTOMIZE_SCRIPT}.bak.$(date +%Y%m%d%H%M%S)"

# 插入补丁
head -n "${TARGET_LINE}" "${CUSTOMIZE_SCRIPT}" > "${CUSTOMIZE_SCRIPT}.tmp"
echo "${PATCH_CONTENT}" >> "${CUSTOMIZE_SCRIPT}.tmp"
tail -n +$((TARGET_LINE + 1)) "${CUSTOMIZE_SCRIPT}" >> "${CUSTOMIZE_SCRIPT}.tmp"
mv "${CUSTOMIZE_SCRIPT}.tmp" "${CUSTOMIZE_SCRIPT}"

echo "✓ 补丁应用成功！"
echo ""
echo "自定义脚本已更新: ${CUSTOMIZE_SCRIPT}"
echo ""
echo "下一步:"
echo "  1. 下载内核 deb 包:"
echo "     ./scripts/download-kernel.sh ${KERNEL_VERSION}"
echo ""
echo "  2. 复制到项目目录:"
echo "     cp kernel-debs/*.deb ubuntu-autoinstall/extras/debs/"
echo ""
echo "  3. 构建 ISO:"
echo "     cd ubuntu-autoinstall && sudo bash build.sh"
echo ""
