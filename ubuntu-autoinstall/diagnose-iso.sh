#!/bin/bash
# diagnose-iso.sh — 排查定制 ISO 启动失败
# 用法：sudo bash diagnose-iso.sh /path/to/your-autoinstall.iso
set -uo pipefail

ISO="${1:-/home/isobuild/ubuntu-22.04-autoinstall-$(date '+%Y%m%d').iso}"
MNT="/mnt/_diag_iso"
SQUASHFS_MNT="/mnt/_diag_squashfs"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}[OK]${NC}   $*"; }
fail() { echo -e "  ${RED}[FAIL]${NC} $*"; ERRORS=$((ERRORS+1)); }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $*"; }
info() { echo -e "  ${BLUE}[INFO]${NC} $*"; }
section() { echo -e "\n${BOLD}═══ $* ═══${NC}"; }

ERRORS=0

[[ $EUID -ne 0 ]] && { echo "请以 root 运行：sudo bash $0 [iso路径]"; exit 1; }

section "1. ISO 文件检查"

if [[ -f "${ISO}" ]]; then
  ok "ISO 存在：${ISO}（$(du -sh "${ISO}" | cut -f1)）"
else
  fail "ISO 不存在：${ISO}"
  echo "  用法：sudo bash $0 /path/to/your.iso"
  exit 1
fi

# 检查 ISO 是否可挂载
mkdir -p "${MNT}"
umount "${MNT}" 2>/dev/null || true
if mount -o loop,ro "${ISO}" "${MNT}" 2>/dev/null; then
  ok "ISO 可正常挂载"
else
  fail "ISO 无法挂载（可能损坏）"
  exit 1
fi

section "2. ISO 顶层目录结构"
echo "  $(ls "${MNT}/" | tr '\n' '  ')"

for d in boot casper EFI autoinstall extras; do
  if [[ -d "${MNT}/${d}" ]]; then
    ok "${d}/ 存在"
  else
    [[ "$d" == "extras" ]] && warn "${d}/ 不存在（可选）" || fail "${d}/ 缺失"
  fi
done

section "3. GRUB 引导配置"

GRUB_CFG="${MNT}/boot/grub/grub.cfg"
if [[ -f "${GRUB_CFG}" ]]; then
  ok "grub.cfg 存在"

  if grep -q "autoinstall" "${GRUB_CFG}"; then
    ok "grub.cfg 包含 autoinstall 参数"
  else
    fail "grub.cfg 未包含 autoinstall 参数"
  fi

  if grep -q 'ds=nocloud' "${GRUB_CFG}"; then
    ok "grub.cfg 包含 ds=nocloud 数据源"
  else
    fail "grub.cfg 未包含 ds=nocloud"
  fi

  # 检查 vmlinuz/initrd 路径是否匹配实际文件
  VMLINUZ_PATH=$(grep -oP 'linux\s+\K/casper/[^ ]+' "${GRUB_CFG}" | head -1)
  INITRD_PATH=$(grep -oP 'initrd\s+\K/casper/[^ ]+' "${GRUB_CFG}" | head -1)

  if [[ -n "${VMLINUZ_PATH}" && -f "${MNT}${VMLINUZ_PATH}" ]]; then
    ok "vmlinuz 路径正确：${VMLINUZ_PATH}（$(du -sh "${MNT}${VMLINUZ_PATH}" | cut -f1)）"
  else
    fail "vmlinuz 路径无效：${VMLINUZ_PATH:-未设置}"
    info "casper/ 中实际内核文件："
    ls -la "${MNT}/casper/"vmlinuz* "${MNT}/casper/"hwe-vmlinuz* 2>/dev/null | sed 's/^/    /'
  fi

  if [[ -n "${INITRD_PATH}" && -f "${MNT}${INITRD_PATH}" ]]; then
    ok "initrd 路径正确：${INITRD_PATH}（$(du -sh "${MNT}${INITRD_PATH}" | cut -f1)）"
  else
    fail "initrd 路径无效：${INITRD_PATH:-未设置}"
    info "casper/ 中实际 initrd 文件："
    ls -la "${MNT}/casper/"initrd* "${MNT}/casper/"hwe-initrd* 2>/dev/null | sed 's/^/    /'
  fi

  info "grub.cfg 引导菜单条目："
  grep "menuentry" "${GRUB_CFG}" | sed 's/^/    /'
else
  fail "grub.cfg 不存在"
fi

# EFI 引导
EFI_GRUB="${MNT}/EFI/boot/grub.cfg"
if [[ -f "${EFI_GRUB}" ]]; then
  ok "EFI grub.cfg 存在"
  info "EFI grub.cfg 内容（前 10 行）："
  head -10 "${EFI_GRUB}" | sed 's/^/    /'
elif [[ -f "${MNT}/EFI/boot/bootx64.efi" ]]; then
  ok "EFI bootx64.efi 存在"
else
  warn "未发现 EFI 引导文件"
fi

section "4. autoinstall 配置"

USER_DATA="${MNT}/autoinstall/user-data"
META_DATA="${MNT}/autoinstall/meta-data"

if [[ -f "${USER_DATA}" ]]; then
  ok "user-data 存在（$(wc -c < "${USER_DATA}") 字节）"

  # YAML 校验
  if command -v python3 &>/dev/null; then
    if python3 -c "import yaml; yaml.safe_load(open('${USER_DATA}'))" 2>/dev/null; then
      ok "user-data YAML 语法正确"
    else
      fail "user-data YAML 语法错误"
      python3 -c "import yaml; yaml.safe_load(open('${USER_DATA}'))" 2>&1 | sed 's/^/    /'
    fi
  fi

  # 关键字段检查
  if grep -q "autoinstall:" "${USER_DATA}"; then
    ok "包含 autoinstall 顶层键"
  else
    fail "缺少 autoinstall 顶层键（这是必须的）"
  fi

  if grep -q "version:" "${USER_DATA}"; then
    ok "包含 version 字段"
  else
    fail "缺少 version 字段"
  fi

  if grep -q "identity:" "${USER_DATA}"; then
    ok "包含 identity 配置"
  else
    fail "缺少 identity 配置（用户名/密码）"
  fi

  if grep -q "storage:" "${USER_DATA}"; then
    ok "包含 storage 配置"
    # 检查目标磁盘
    TARGET_DISK=$(grep -oP 'path:\s*\K/dev/\S+' "${USER_DATA}" | head -1)
    [[ -n "${TARGET_DISK}" ]] && info "目标磁盘：${TARGET_DISK}" || info "目标磁盘：自动选择"
  else
    warn "未包含 storage 配置（使用默认分区）"
  fi
else
  fail "user-data 不存在！autoinstall 将无法工作"
fi

if [[ -f "${META_DATA}" ]]; then
  ok "meta-data 存在"
else
  fail "meta-data 不存在（cloud-init 需要此文件，即使为空）"
fi

section "5. casper/ squashfs 检查"

echo "  casper/ 中的 squashfs 文件："
ls -lh "${MNT}/casper/"*.squashfs 2>/dev/null | awk '{print "    "$NF" ("$5")"}' || fail "casper/ 中无 squashfs 文件"

# 检查 install-sources.yaml
INSTALL_SRC="${MNT}/casper/install-sources.yaml"
if [[ -f "${INSTALL_SRC}" ]]; then
  ok "install-sources.yaml 存在"
  info "内容："
  cat "${INSTALL_SRC}" | sed 's/^/    /'

  # 验证引用的 squashfs 是否存在
  while IFS= read -r uri; do
    SQFS_PATH="${MNT}/${uri}"
    if [[ -f "${SQFS_PATH}" ]]; then
      ok "引用的 squashfs 存在：${uri}（$(du -sh "${SQFS_PATH}" | cut -f1)）"
    else
      fail "引用的 squashfs 不存在：${uri}"
    fi
  done < <(grep -oP 'cp:///\K\S+' "${INSTALL_SRC}")
else
  warn "install-sources.yaml 不存在（Subiquity 可能用默认加载逻辑）"
fi

# 检查 .gpg 签名文件。当前构建只替换 server 层，该层签名必须删除；
# 其他未修改层保留官方签名是正常现象。
CUSTOM_SERVER_GPG="${MNT}/casper/ubuntu-server-minimal.ubuntu-server.squashfs.gpg"
GPG_FILES=$(ls "${MNT}/casper/"*.squashfs.gpg 2>/dev/null | wc -l)
SQFS_FILES=$(ls "${MNT}/casper/"*.squashfs 2>/dev/null | wc -l)
if [[ -f "${CUSTOM_SERVER_GPG}" ]]; then
  fail "定制 server 层仍保留失效签名：$(basename "${CUSTOM_SERVER_GPG}")"
elif [[ ${GPG_FILES} -gt 0 ]]; then
  ok "定制 server 层无残留签名，保留 ${GPG_FILES} 个未修改层官方签名"
elif [[ ${SQFS_FILES} -gt 0 ]]; then
  ok "无残留 .squashfs.gpg 签名文件"
fi

# 尝试挂载 squashfs 验证完整性（优先选 install-sources.yaml 引用的文件）
SQFS_FILE=""
if [[ -f "${INSTALL_SRC}" ]]; then
  SQFS_REF=$(grep -oP 'cp:///\K\S+' "${INSTALL_SRC}" | head -1)
  [[ -n "${SQFS_REF}" && -f "${MNT}/${SQFS_REF}" ]] && SQFS_FILE="${MNT}/${SQFS_REF}"
fi
# 回退：选最大的 squashfs 文件
[[ -z "${SQFS_FILE}" ]] && SQFS_FILE=$(ls -S "${MNT}/casper/"*.squashfs 2>/dev/null | head -1)
if [[ -n "${SQFS_FILE}" ]]; then
  mkdir -p "${SQUASHFS_MNT}"
  umount "${SQUASHFS_MNT}" 2>/dev/null || true
  if mount -t squashfs -o loop,ro "${SQFS_FILE}" "${SQUASHFS_MNT}" 2>/dev/null; then
    ok "squashfs 可正常挂载"

    # 检查基础目录（Ubuntu 22.04 使用 merged-usr：/bin → /usr/bin 是符号链接）
    for d in usr etc; do
      [[ -d "${SQUASHFS_MNT}/${d}" ]] && ok "squashfs 包含 /${d}" || fail "squashfs 缺少 /${d}"
    done
    for d in bin sbin lib; do
      if [[ -d "${SQUASHFS_MNT}/${d}" ]]; then
        ok "squashfs 包含 /${d}（目录）"
      elif [[ -L "${SQUASHFS_MNT}/${d}" ]]; then
        ok "squashfs 包含 /${d}（→ $(readlink "${SQUASHFS_MNT}/${d}")，merged-usr 符号链接）"
      else
        fail "squashfs 缺少 /${d}"
      fi
    done

    # 检查 init 系统
    if [[ -e "${SQUASHFS_MNT}/sbin/init" ]]; then
      ok "squashfs 有 /sbin/init"
    elif [[ -e "${SQUASHFS_MNT}/usr/sbin/init" ]]; then
      ok "squashfs 有 /usr/sbin/init（merged-usr）"
    elif [[ -e "${SQUASHFS_MNT}/usr/lib/systemd/systemd" ]]; then
      ok "squashfs 有 systemd（/usr/lib/systemd/systemd）"
    else
      fail "squashfs 缺少 init 系统（无法启动）"
    fi

    # 检查预装包
    info "预装软件验证："
    for pkg in gcc make openssh-server; do
      if chroot "${SQUASHFS_MNT}" dpkg -s "${pkg}" &>/dev/null; then
        ok "${pkg} 已预装"
      else
        warn "${pkg} 未预装"
      fi
    done

    umount "${SQUASHFS_MNT}"
  else
    fail "squashfs 无法挂载（文件可能损坏）"
  fi
fi

section "6. 引导文件完整性"

# 检查 BIOS 引导
if [[ -f "${MNT}/boot/grub/i386-pc/eltorito.img" ]]; then
  ok "eltorito.img 存在（BIOS El Torito 引导）"
else
  warn "eltorito.img 缺失"
fi

# 检查 EFI 引导（注意：boot_hybrid.img 和 efi.img 在 22.04.5 中不在 ISO 内，
# 应从原始 ISO 的 MBR 和 EFI 分区提取后用 xorriso 嵌入）
for f in EFI/boot/bootx64.efi EFI/boot/grubx64.efi; do
  if [[ -f "${MNT}/${f}" ]]; then
    ok "${f} 存在"
  fi
done

section "7. ISO 引导记录检查"

# 检查 ISO 前 512 字节是否有 MBR
MBR_SIG=$(xxd -s 510 -l 2 -p "${ISO}" 2>/dev/null)
if [[ "${MBR_SIG}" == "55aa" ]]; then
  ok "ISO 包含有效 MBR 签名（Legacy BIOS 可引导）"
else
  warn "ISO 无 MBR 签名（仅 UEFI 可引导）"
fi

# 检查 GPT/EFI
if fdisk -l "${ISO}" 2>/dev/null | grep -qi "EFI"; then
  ok "ISO 包含 EFI 分区（UEFI 可引导）"
else
  warn "未检测到 EFI 分区信息"
fi

# 清理
umount "${MNT}" 2>/dev/null || true
rmdir "${SQUASHFS_MNT}" 2>/dev/null || true

section "诊断结果"

if [[ ${ERRORS} -eq 0 ]]; then
  echo -e "\n  ${GREEN}${BOLD}全部通过（0 个错误）${NC}"
  echo ""
  echo "  ISO 结构看起来正常。如果仍无法启动，可能原因："
  echo "    1. 服务器 BIOS/UEFI 设置问题（Secure Boot、Boot Order）"
  echo "    2. 服务器不支持 ISO 中的引导模式（仅 BIOS 或仅 UEFI）"
  echo "    3. BMC/IPMI 虚拟介质挂载问题"
  echo "    4. 安装目标磁盘 /dev/sda 不存在"
else
  echo -e "\n  ${RED}${BOLD}发现 ${ERRORS} 个错误${NC}"
  echo ""
  echo "  请根据上面的 [FAIL] 项修复后重新构建 ISO"
fi
echo ""
