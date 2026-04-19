#!/bin/bash
# build.sh — Ubuntu 22.04 Subiquity AutoInstall ISO 构建脚本
# 支持 squashfs 定制 + 本地 APT 离线仓库 + GPG 签名
set -euo pipefail

# ════════════════ 配置区 ════════════════
UBUNTU_ISO_PATH="${UBUNTU_ISO_PATH:-/opt/ubuntu-22.04.5-live-server-amd64.iso}"
BUILD_DATE="$(date '+%Y%m%d')"
OUTPUT_ISO="${OUTPUT_ISO:-/home/isobuild/ubuntu-22.04-autoinstall-${BUILD_DATE}.iso}"
WORK_DIR="${WORK_DIR:-/tmp/iso-build-work}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# ════════════════════════════════════════

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
step()  { echo -e "\n${BOLD}${BLUE}──── $* ────${NC}"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
ok()    { echo -e "${GREEN}[OK]${NC}   $*"; }

inject_ssh_authorized_keys() {
  local user_data_path="$1"
  local keys_path="$2"

  [[ -s "${keys_path}" ]] || return 0

  python3 - "${user_data_path}" "${keys_path}" <<'PY'
import pathlib
import sys

user_data_path = pathlib.Path(sys.argv[1])
keys_path = pathlib.Path(sys.argv[2])

keys = [
    line.strip()
    for line in keys_path.read_text().splitlines()
    if line.strip() and not line.lstrip().startswith("#")
]
if not keys:
    sys.exit(0)

lines = user_data_path.read_text().splitlines()
out = []
inserted = False
skip_existing = False

for line in lines:
    stripped = line.strip()

    if stripped == "authorized-keys:":
        skip_existing = True
        continue

    if skip_existing:
        if line.startswith("      - "):
            continue
        skip_existing = False

    out.append(line)
    if stripped == "allow-pw: true" and not inserted:
        out.append("    authorized-keys:")
        for key in keys:
            escaped = key.replace("\\", "\\\\").replace('"', '\\"')
            out.append(f'      - "{escaped}"')
        inserted = True

if not inserted:
    raise SystemExit("未在 user-data 中找到 ssh.allow-pw，无法注入 authorized-keys")

user_data_path.write_text("\n".join(out) + "\n")
PY
}

validate_iso_contents() {
  local iso_path="$1"
  local required_paths=(
    "autoinstall/user-data"
    "autoinstall/meta-data"
    "extras/scripts/post-install.sh"
    "extras/config/kernel.env"
    "boot/grub/grub.cfg"
  )
  local path=""
  local mount_dir

  mount_dir="$(mktemp -d)"

  step "验证输出 ISO 内容"
  mount -o loop,ro "${iso_path}" "${mount_dir}"
  for path in "${required_paths[@]}"; do
    if [[ -e "${mount_dir}/${path}" ]]; then
      ok "ISO 中存在 /${path}"
    else
      umount "${mount_dir}" || true
      rmdir "${mount_dir}" || true
      error "输出 ISO 缺少关键文件：/${path}"
    fi
  done
  umount "${mount_dir}"
  rmdir "${mount_dir}"
}

[[ $EUID -ne 0 ]] && error "请以 root 权限运行：sudo bash $0"

# ──── 第 1 步：依赖检查 ────
step "依赖检查"
MISSING=()
for cmd in xorriso python3 unsquashfs mksquashfs; do
  if command -v "$cmd" &>/dev/null; then
    ok "$cmd"
  else
    warn "$cmd 缺失"
    MISSING+=("$cmd")
  fi
done
if [[ ${#MISSING[@]} -gt 0 ]]; then
  info "安装缺失工具..."
  # 映射命令到包名
  PKGS=()
  for cmd in "${MISSING[@]}"; do
    case "$cmd" in
      xorriso)           PKGS+=("xorriso") ;;
      curl)              PKGS+=("curl") ;;
      python3)           PKGS+=("python3") ;;
      unsquashfs|mksquashfs) PKGS+=("squashfs-tools") ;;
      *)                 PKGS+=("$cmd") ;;
    esac
  done
  # 去重
  PKGS=($(printf '%s\n' "${PKGS[@]}" | sort -u))
  apt-get update -q && apt-get install -y -q "${PKGS[@]}"
fi

# 验证 user-data
[[ -f "${SCRIPT_DIR}/user-data" ]] || error "user-data 不存在：${SCRIPT_DIR}/user-data"
python3 -c "
import yaml, sys
try:
    yaml.safe_load(open('${SCRIPT_DIR}/user-data'))
    print('[OK]   user-data YAML 格式正确')
except ImportError:
    print('[WARN] python3-yaml 未安装，跳过格式校验')
except Exception as e:
    print(f'[ERROR] user-data 格式错误：{e}'); sys.exit(1)
"

# 磁盘空间检查
mkdir -p "$(dirname "${OUTPUT_ISO}")"
AVAIL=$(( $(df -k "$(dirname "${OUTPUT_ISO}")" | awk 'NR==2{print $4}') / 1024 / 1024 ))
[[ ${AVAIL} -lt 10 ]] && error "输出目录磁盘空间不足（需 10GB，现有 ${AVAIL}GB）"
ok "磁盘空间：${AVAIL}GB"

# ──── 第 2 步：检查本地 ISO ────
step "检查本地 Ubuntu ISO"
[[ -f "${UBUNTU_ISO_PATH}" ]] || error "ISO 不存在：${UBUNTU_ISO_PATH}（请手动下载后放到该路径）"
ok "使用本地 ISO：${UBUNTU_ISO_PATH}（$(du -sh "${UBUNTU_ISO_PATH}" | cut -f1)）"

# ──── 第 3 步：解包 ISO ────
step "解包 ISO"
rm -rf "${WORK_DIR}"; mkdir -p "${WORK_DIR}"
mkdir -p /mnt/_iso_ro
mount -o loop,ro "${UBUNTU_ISO_PATH}" /mnt/_iso_ro
cp -a /mnt/_iso_ro/. "${WORK_DIR}/"
umount /mnt/_iso_ro
chmod -R u+w "${WORK_DIR}"
[[ -f "${WORK_DIR}/casper/vmlinuz" ]] || error "不是有效的 Ubuntu Server Live ISO"
ok "解包完成（$(du -sh "${WORK_DIR}" | cut -f1)）"

# ──── 第 4 步：定制 squashfs ────
step "定制 squashfs（预装软件包 + GPG 密钥）"
if [[ -f "${SCRIPT_DIR}/customize-squashfs.sh" ]]; then
  bash "${SCRIPT_DIR}/customize-squashfs.sh" "${WORK_DIR}"
  ok "squashfs 定制完成"
else
  warn "未发现 customize-squashfs.sh，使用官方原版 squashfs"
fi

# 安全检查：验证 casper/ 中关键 squashfs 文件完整
step "验证 casper/ squashfs 完整性"
info "casper/ 中 squashfs 文件："
ls -lhS "${WORK_DIR}/casper/"*.squashfs 2>/dev/null | awk '{printf "  %s (%s)\n", $NF, $5}'
for sqfs in \
  "${WORK_DIR}/casper/ubuntu-server-minimal.squashfs" \
  "${WORK_DIR}/casper/ubuntu-server-minimal.ubuntu-server.squashfs" \
  "${WORK_DIR}/casper/ubuntu-server-minimal.ubuntu-server.installer.generic.squashfs"; do
  if [[ -f "${sqfs}" ]]; then
    ok "$(basename "${sqfs}") 存在"
  else
    error "$(basename "${sqfs}") 缺失！initrd 需要此文件"
  fi
done

# ──── 第 5 步：注入 autoinstall 配置 ────
step "注入 autoinstall 配置"
mkdir -p "${WORK_DIR}/autoinstall"
cp "${SCRIPT_DIR}/user-data" "${WORK_DIR}/autoinstall/user-data"
cp "${SCRIPT_DIR}/meta-data" "${WORK_DIR}/autoinstall/meta-data"
ok "autoinstall/ 注入完成"

# ──── 第 6 步：注入 extras ────
step "注入 extras（脚本 / 驱动 / 密钥）"
cp -r "${SCRIPT_DIR}/extras" "${WORK_DIR}/extras"
chmod +x "${WORK_DIR}/extras/scripts/"*.sh 2>/dev/null || true
find "${WORK_DIR}/extras" -name '._*' -delete 2>/dev/null || true

MLNX=$(ls "${WORK_DIR}/extras/drivers/"MLNX_OFED*.tgz 2>/dev/null | head -1 || true)
NVCR=$(ls "${WORK_DIR}/extras/drivers/"NVIDIA-Linux*.run 2>/dev/null | head -1 || true)
KEYS="${WORK_DIR}/extras/keys/authorized_keys"

[[ -n "${MLNX}" ]] && ok "Mellanox OFED ：$(basename "${MLNX}")" \
                    || warn "未发现 Mellanox OFED（可选，构建继续）"
[[ -n "${NVCR}" ]] && ok "NVIDIA 驱动   ：$(basename "${NVCR}")" \
                    || warn "未发现 NVIDIA 驱动（可选，构建继续）"
if [[ -s "${KEYS}" ]]; then
  KEY_COUNT=$(grep -c "^ssh-" "${KEYS}" 2>/dev/null || echo 0)
  ok "SSH 公钥     ：${KEY_COUNT} 条"
  inject_ssh_authorized_keys "${WORK_DIR}/autoinstall/user-data" "${KEYS}"
  ok "autoinstall 已注入 authorized-keys"
else
  warn "authorized_keys 为空（安装后无密钥登录）"
fi

# ──── 第 7 步：修改 GRUB ────
step "修改 GRUB 引导参数"
GRUB_CFG="${WORK_DIR}/boot/grub/grub.cfg"
cp "${GRUB_CFG}" "${GRUB_CFG}.orig"

cat > "${GRUB_CFG}" << 'GRUBEOF'
set default=0
set timeout=5

if loadfont /boot/grub/font.pf2; then
  set gfxmode=auto
  insmod efi_gop
  insmod efi_uga
  insmod gfxterm
  terminal_output gfxterm
fi

menuentry "Ubuntu 22.04 AutoInstall" {
    set gfxpayload=keep
    linux  /casper/vmlinuz quiet splash autoinstall ds=nocloud\;s=/cdrom/autoinstall/ ---
    initrd /casper/initrd
}

menuentry "Ubuntu 22.04 AutoInstall (Safe Graphics)" {
    set gfxpayload=keep
    linux  /casper/vmlinuz quiet splash nomodeset autoinstall ds=nocloud\;s=/cdrom/autoinstall/ ---
    initrd /casper/initrd
}

menuentry "Ubuntu 22.04 Interactive Install" {
    set gfxpayload=keep
    linux  /casper/vmlinuz quiet splash ---
    initrd /casper/initrd
}
GRUBEOF

if [[ -f "${WORK_DIR}/isolinux/txt.cfg" ]]; then
  cat > "${WORK_DIR}/isolinux/txt.cfg" << 'IEOF'
default autoinstall
label autoinstall
  menu label Ubuntu 22.04 AutoInstall
  kernel /casper/vmlinuz
  append initrd=/casper/initrd quiet splash autoinstall ds=nocloud;s=/cdrom/autoinstall/ ---
IEOF
fi
ok "GRUB 配置完成"

# ──── 第 8 步：从原始 ISO 提取引导记录 ────
step "提取原始 ISO 引导记录"
MBR_BIN="/tmp/iso-mbr.bin"
EFI_PART="/tmp/efi-part.img"

# 提取 MBR（前 432 字节，不覆盖分区表）
dd if="${UBUNTU_ISO_PATH}" bs=1 count=432 of="${MBR_BIN}" 2>/dev/null
ok "MBR 已提取（$(wc -c < "${MBR_BIN}") 字节）"

# 从原始 ISO 提取 EFI 系统分区镜像
EFI_START=$(fdisk -l "${UBUNTU_ISO_PATH}" 2>/dev/null | grep -i "EFI" | awk '{print $2}')
EFI_END=$(fdisk -l "${UBUNTU_ISO_PATH}" 2>/dev/null | grep -i "EFI" | awk '{print $3}')

if [[ -n "${EFI_START}" && -n "${EFI_END}" ]]; then
  EFI_SIZE=$((EFI_END - EFI_START + 1))
  dd if="${UBUNTU_ISO_PATH}" bs=512 skip="${EFI_START}" count="${EFI_SIZE}" of="${EFI_PART}" 2>/dev/null
  ok "EFI 分区已提取（$(du -sh "${EFI_PART}" | cut -f1)）"
else
  # 备选方案：尝试用 xorriso 从原始 ISO 获取引导参数
  warn "fdisk 未找到 EFI 分区，尝试 xorriso 提取..."
  xorriso -indev "${UBUNTU_ISO_PATH}" -report_el_torito as_mkisofs 2>&1 | head -20
  error "无法提取 EFI 引导分区，请检查源 ISO 完整性"
fi

# ──── 第 9 步：封装 ISO ────
step "封装 ISO（UEFI + Legacy BIOS 双模式）"
rm -f "${OUTPUT_ISO}"

xorriso -as mkisofs \
  -r -V "Ubuntu-2204-AutoInstall" \
  -o "${OUTPUT_ISO}" \
  --grub2-mbr "${MBR_BIN}" \
  -partition_offset 16 --mbr-force-bootable \
  -append_partition 2 28732ac11ff8d211ba4b00a0c93ec93b "${EFI_PART}" \
  -appended_part_as_gpt \
  -iso_mbr_part_type a2a0d0ebe5b9334487c068b6b72699c7 \
  -c '/boot.catalog' \
  -b '/boot/grub/i386-pc/eltorito.img' \
  -no-emul-boot -boot-load-size 4 -boot-info-table --grub2-boot-info \
  -eltorito-alt-boot \
  -e '--interval:appended_partition_2:::' \
  -no-emul-boot \
  "${WORK_DIR}" 2>&1 | tail -5

validate_iso_contents "${OUTPUT_ISO}"

# 清理临时文件
rm -f "${MBR_BIN}" "${EFI_PART}"

rm -rf "${WORK_DIR}"

echo ""
echo -e "${BOLD}${GREEN}"
echo "  ╔══════════════════════════════════════════════════╗"
echo "  ║            ISO 构建成功！                        ║"
echo "  ╚══════════════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "  输出文件：${OUTPUT_ISO}（$(du -sh "${OUTPUT_ISO}" | cut -f1)）"
echo ""
echo -e "  刻录 U 盘：${BOLD}sudo dd if=${OUTPUT_ISO} of=/dev/sdX bs=4M status=progress${NC}"
echo ""
echo -e "  ${RED}${BOLD}  ISO 启动后将自动安装，目标磁盘数据将被清空！${NC}"
echo ""
