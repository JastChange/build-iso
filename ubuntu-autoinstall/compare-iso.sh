#!/bin/bash
# compare-iso.sh — 对比原始 ISO 与定制 ISO 的 casper/ 结构
# 用法：sudo bash compare-iso.sh <原始ISO> <定制ISO>
set -uo pipefail

ORIG_ISO="${1:?用法: $0 <原始ISO路径> <定制ISO路径>}"
CUSTOM_ISO="${2:?用法: $0 <原始ISO路径> <定制ISO路径>}"
MNT_ORIG="/mnt/_cmp_orig"
MNT_CUSTOM="/mnt/_cmp_custom"

BOLD='\033[1m'; NC='\033[0m'
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
section() { echo -e "\n${BOLD}═══ $* ═══${NC}"; }
ok()   { echo -e "  ${GREEN}[OK]${NC}   $*"; }
diff_() { echo -e "  ${RED}[DIFF]${NC} $*"; }
info() { echo -e "  ${BLUE}[INFO]${NC} $*"; }

[[ $EUID -ne 0 ]] && { echo "需要 root：sudo bash $0 <原始> <定制>"; exit 1; }
[[ -f "${ORIG_ISO}" ]]   || { echo "原始 ISO 不存在：${ORIG_ISO}"; exit 1; }
[[ -f "${CUSTOM_ISO}" ]] || { echo "定制 ISO 不存在：${CUSTOM_ISO}"; exit 1; }

# 挂载
mkdir -p "${MNT_ORIG}" "${MNT_CUSTOM}"
umount "${MNT_ORIG}" "${MNT_CUSTOM}" 2>/dev/null || true
mount -o loop,ro "${ORIG_ISO}" "${MNT_ORIG}"
mount -o loop,ro "${CUSTOM_ISO}" "${MNT_CUSTOM}"

cleanup() { umount "${MNT_ORIG}" "${MNT_CUSTOM}" 2>/dev/null || true; }
trap cleanup EXIT

# ═══════════════════════════════════════
section "1. casper/ 目录文件对比"
# ═══════════════════════════════════════

echo -e "\n  ${BOLD}原始 ISO casper/ 文件：${NC}"
ls -lhS "${MNT_ORIG}/casper/" 2>/dev/null | tail -n +2 | awk '{printf "    %-60s %s\n", $NF, $5}'

echo -e "\n  ${BOLD}定制 ISO casper/ 文件：${NC}"
ls -lhS "${MNT_CUSTOM}/casper/" 2>/dev/null | tail -n +2 | awk '{printf "    %-60s %s\n", $NF, $5}'

# 列出原始有但定制缺失的文件
echo -e "\n  ${BOLD}差异分析：${NC}"
for f in "${MNT_ORIG}/casper/"*; do
  fname=$(basename "$f")
  if [[ ! -e "${MNT_CUSTOM}/casper/${fname}" ]]; then
    diff_ "定制 ISO 缺失：${fname}"
  fi
done

for f in "${MNT_CUSTOM}/casper/"*; do
  fname=$(basename "$f")
  if [[ ! -e "${MNT_ORIG}/casper/${fname}" ]]; then
    info "定制 ISO 新增：${fname}"
  fi
done

# ═══════════════════════════════════════
section "2. install-sources.yaml 对比"
# ═══════════════════════════════════════

echo -e "\n  ${BOLD}原始 ISO：${NC}"
if [[ -f "${MNT_ORIG}/casper/install-sources.yaml" ]]; then
  cat "${MNT_ORIG}/casper/install-sources.yaml" | sed 's/^/    /'
else
  diff_ "原始 ISO 无 install-sources.yaml"
fi

echo -e "\n  ${BOLD}定制 ISO：${NC}"
if [[ -f "${MNT_CUSTOM}/casper/install-sources.yaml" ]]; then
  cat "${MNT_CUSTOM}/casper/install-sources.yaml" | sed 's/^/    /'
else
  diff_ "定制 ISO 无 install-sources.yaml"
fi

# 验证 install-sources.yaml 引用的每个文件是否存在
echo -e "\n  ${BOLD}定制 ISO 引用验证：${NC}"
if [[ -f "${MNT_CUSTOM}/casper/install-sources.yaml" ]]; then
  grep -oP 'cp:///\K\S+' "${MNT_CUSTOM}/casper/install-sources.yaml" | while read -r uri; do
    if [[ -f "${MNT_CUSTOM}/${uri}" ]]; then
      ok "${uri} 存在（$(du -sh "${MNT_CUSTOM}/${uri}" | cut -f1)）"
    else
      diff_ "${uri} 不存在！"
    fi
  done
fi

# ═══════════════════════════════════════
section "3. squashfs 文件清单对比"
# ═══════════════════════════════════════

echo -e "\n  ${BOLD}原始 ISO .squashfs 文件（含签名）：${NC}"
ls -1 "${MNT_ORIG}/casper/"*.squashfs* 2>/dev/null | while read -r f; do
  echo "    $(basename "$f")  ($(du -sh "$f" | cut -f1))"
done

echo -e "\n  ${BOLD}定制 ISO .squashfs 文件（含签名）：${NC}"
ls -1 "${MNT_CUSTOM}/casper/"*.squashfs* 2>/dev/null | while read -r f; do
  echo "    $(basename "$f")  ($(du -sh "$f" | cut -f1))"
done

# ═══════════════════════════════════════
section "4. initrd 内 casper 脚本分析"
# ═══════════════════════════════════════

# 解包 initrd 查看它到底期望什么文件
INITRD="${MNT_ORIG}/casper/initrd"
if [[ -f "${INITRD}" ]]; then
  TMPDIR=$(mktemp -d)
  info "解包原始 initrd 分析引导逻辑..."

  # initrd 可能是多段拼接（microcode + 主 cpio），取最后一段
  cd "${TMPDIR}"
  unmkinitramfs "${INITRD}" "${TMPDIR}/initrd-content" 2>/dev/null || {
    # 回退：手动解包
    zcat "${INITRD}" 2>/dev/null | cpio -idm 2>/dev/null || \
    lz4 -dc "${INITRD}" 2>/dev/null | cpio -idm 2>/dev/null || \
    xz -dc "${INITRD}" 2>/dev/null | cpio -idm 2>/dev/null || true
  }

  # 搜索 casper 相关脚本
  echo ""
  info "initrd 中与 casper/squashfs 相关的脚本："
  find "${TMPDIR}" -type f 2>/dev/null | xargs grep -l "squashfs\|casper\|filesystem\|layers" 2>/dev/null | while read -r f; do
    echo "    ${f#${TMPDIR}/}"
  done

  # 查找 initrd 中定义文件系统层的关键逻辑
  echo ""
  info "initrd 中查找 squashfs 的关键代码："
  find "${TMPDIR}" -type f 2>/dev/null | xargs grep -n "\.squashfs\|filesystem\.layers\|layerfs\|casper.*mount\|find.*squashfs" 2>/dev/null | \
    grep -v "Binary" | head -40 | while read -r line; do
    echo "    ${line#${TMPDIR}/}"
  done

  # 特别查找 ubuntu-server-minimal 相关引用
  echo ""
  info "initrd 中 'ubuntu-server-minimal' 相关引用："
  find "${TMPDIR}" -type f 2>/dev/null | xargs grep -rn "ubuntu-server-minimal" 2>/dev/null | \
    grep -v "Binary" | head -20 | while read -r line; do
    echo "    ${line#${TMPDIR}/}"
  done

  # 查找文件系统层的配置/期望
  echo ""
  info "initrd 中 'layers' 或 'filesystem' 关键逻辑："
  find "${TMPDIR}" -type f -name "*.conf" -o -name "*.cfg" -o -name "*.sh" 2>/dev/null | \
    xargs grep -ln "layer\|filesystem\|squashfs" 2>/dev/null | while read -r f; do
    echo ""
    echo "    === ${f#${TMPDIR}/} ==="
    grep -n "layer\|filesystem\|squashfs\|mount.*casper" "$f" 2>/dev/null | head -20 | while read -r line; do
      echo "      ${line}"
    done
  done

  rm -rf "${TMPDIR}"
  cd /
else
  diff_ "原始 initrd 不存在"
fi

# ═══════════════════════════════════════
section "5. GRUB + EFI 引导对比"
# ═══════════════════════════════════════

echo -e "\n  ${BOLD}原始 ISO boot/grub/grub.cfg（前 30 行）：${NC}"
head -30 "${MNT_ORIG}/boot/grub/grub.cfg" 2>/dev/null | sed 's/^/    /'

echo -e "\n  ${BOLD}定制 ISO boot/grub/grub.cfg（前 30 行）：${NC}"
head -30 "${MNT_CUSTOM}/boot/grub/grub.cfg" 2>/dev/null | sed 's/^/    /'

echo -e "\n  ${BOLD}EFI 结构对比：${NC}"
echo "  原始："
ls -la "${MNT_ORIG}/EFI/boot/" 2>/dev/null | sed 's/^/    /'
echo "  定制："
ls -la "${MNT_CUSTOM}/EFI/boot/" 2>/dev/null | sed 's/^/    /'

# ═══════════════════════════════════════
section "6. 顶层目录对比"
# ═══════════════════════════════════════

echo -e "  ${BOLD}原始：${NC} $(ls "${MNT_ORIG}/" | tr '\n' '  ')"
echo -e "  ${BOLD}定制：${NC} $(ls "${MNT_CUSTOM}/" | tr '\n' '  ')"

section "完成"
echo "  请将以上输出发给我，我会根据差异制定精确修复方案。"
echo ""
