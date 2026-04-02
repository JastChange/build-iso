# Ubuntu 22.04 Subiquity 全自动安装 ISO 构建系统

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 构建一个基于 Ubuntu 官方 Subiquity 安装器的全自动 ISO，支持无人值守安装、驱动预装（Mellanox OFED / NVIDIA）、SSH 密钥写入、自定义脚本执行。

**Architecture:** 用 Ubuntu 22.04 Server ISO 作为安装器载体，**定制 squashfs**（预装编译工具链、特定版本驱动等），并嵌入**本地 APT 离线仓库**（GPG 签名）。通过 `autoinstall user-data` 的 `late-commands` 阶段执行驱动安装和自定义脚本。驱动文件、脚本、SSH 密钥、离线仓库均预先嵌入 ISO，安装时从 `/cdrom/extras/` 读取，全程无需网络。

**Key Changes vs Original:**
- squashfs 不再保持官方原版，而是解包 → chroot 预装软件 → 重打包
- 新增本地 APT 仓库（GPG 签名），支持安装后离线 `apt install`
- 支持替换特定版本 deb 包（如自编译驱动）

**Tech Stack:** Ubuntu 22.04 Server ISO · Subiquity autoinstall · xorriso · bash · curtin

---

## 为什么放弃 penguins-eggs

| 问题 | 说明 |
|------|------|
| 只能打包当前运行系统 | 无法在 Ubuntu 24.04 宿主机上构建 Ubuntu 22.04 ISO |
| Krill 分区方案固定 | 需要改 TypeScript 源码才能自定义 |
| 不支持 autoinstall | 无法与标准 cloud-init 生态集成 |
| PPA 地址 404 | penguins-eggs 安装本身就失败 |

---

## 新旧方案对比

| 维度 | 旧（penguins-eggs） | 新（Subiquity + 定制） |
|------|---------------------|----------------------|
| 构建时间 | 45～90 分钟 | **10～25 分钟**（含 squashfs 定制） |
| ISO 大小 | 4～8 GB | **2～5 GB**（含离线仓库） |
| 分区配置 | 改 TypeScript 源码 | **YAML 声明** |
| 驱动安装 | squashfs 预装 | **squashfs 预装 + late-commands** |
| 离线包管理 | 无 | **✅ 本地 APT 仓库（GPG 签名）** |
| 特定版本包 | 手动替换 | **✅ extras/debs/ 自动替换** |
| SSH 密钥写入 | 无内置支持 | **✅ late-commands 写入** |
| 自动安装 | 有限支持 | **✅ 完整 autoinstall** |
| 依赖 | Node.js + eggs + PPA | **xorriso + squashfs-tools + bash** |

---

## 最终项目结构

```
ubuntu-autoinstall/
├── build.sh                        ← 主构建脚本（唯一入口）
├── customize-squashfs.sh           ← squashfs 定制脚本（build.sh 调用）
├── build-repo.sh                   ← 本地 APT 仓库构建脚本
├── user-data                       ← autoinstall 配置（YAML）
├── meta-data                       ← cloud-init 元数据（空文件，必须存在）
└── extras/                         ← 嵌入 ISO 的附加内容
    ├── scripts/
    │   ├── post-install.sh         ← 安装后主脚本（late-commands 调用）
    │   ├── install-mlnx.sh         ← Mellanox OFED 安装逻辑
    │   └── install-nvidia.sh       ← NVIDIA 驱动安装逻辑
    ├── keys/
    │   ├── authorized_keys         ← 要写入目标机的 SSH 公钥
    │   └── repo-signing.gpg        ← APT 仓库签名公钥（build-repo.sh 生成）
    ├── repo/                       ← 本地 APT 离线仓库（build-repo.sh 生成）
    │   ├── pool/                   ← deb 包存放目录
    │   ├── Packages.gz             ← 包索引
    │   ├── Release                 ← 仓库元数据
    │   └── Release.gpg             ← GPG 签名
    ├── debs/                       ← 需要预装到 squashfs 的 deb 包（手动放入）
    │   └── *.deb                   ← 特定版本驱动等
    └── drivers/                    ← 驱动文件（构建前手动放入）
        ├── MLNX_OFED_LINUX-*.tgz   ← Mellanox OFED（可选）
        └── NVIDIA-Linux-x86_64-*.run ← NVIDIA 驱动（可选）
```

---

## 构建流程（build.sh）

```
1. 依赖检查（xorriso, python3, squashfs-tools, dpkg-dev, gpg）
       │
2. 检查本地 Ubuntu 22.04 Server ISO（需预先下载）
       │
3. 解包 ISO → ${WORK_DIR}/
       │
4. ★ 定制 squashfs（customize-squashfs.sh）：
       ├─ unsquashfs 解包 casper/filesystem.squashfs
       ├─ chroot 进入解包目录
       ├─ 导入 GPG 公钥到 trusted.gpg.d/
       ├─ apt-get update + 安装编译工具链
       ├─ dpkg -i 替换特定版本 deb 包（如有）
       ├─ 清理缓存
       ├─ mksquashfs 重新打包（xz 压缩）
       └─ 更新 filesystem.size
       │
5. 注入 autoinstall 配置（user-data + meta-data）
       │
6. 注入 extras（脚本 / 驱动 / 密钥 / 本地仓库）
       │
7. 修改 GRUB 引导参数
       │
8. xorriso 封装 ISO（UEFI + Legacy BIOS 双模式）
```

## 安装流程（运行时）

```
1. 服务器插入 ISO 启动
       │
2. GRUB 引导（倒计 5 秒）
       │  内核参数：autoinstall ds=nocloud;s=/cdrom/autoinstall/
       │
3. Subiquity 读取 /cdrom/autoinstall/user-data
       │
4. 全自动执行基础安装：
       ├─ 格式化磁盘：EFI(512M) + /boot(4G) + /(其余)，无 swap
       ├─ 安装 Ubuntu 基础系统（★ 定制 squashfs，已含编译工具链）
       ├─ 配置用户 / 网络 / 时区 / SSH
       │
5. late-commands 阶段：
       ├─ 复制 /cdrom/extras/ → /target/opt/extras/
       ├─ 写入 SSH authorized_keys
       ├─ ★ 配置离线 APT 仓库（GPG 签名已信任）
       ├─ curtin in-target -- bash /opt/extras/scripts/post-install.sh
       │     ├─ 检测到 MLNX_OFED*.tgz → 执行 install-mlnx.sh
       │     └─ 检测到 NVIDIA*.run    → 执行 install-nvidia.sh
       │                                  + 注册 firstboot 服务
       └─ 配置 sudo 免密
       │
6. 系统重启
       │
7. 首次启动：
       ├─ nvidia-driver-firstboot.service 自动编译内核模块 → 再次重启生效
       └─ ★ 离线 APT 仓库可用，apt install 无需网络
```

---

## 触发逻辑

```
extras/debs/*.deb 存在                → squashfs 定制时自动 dpkg -i 替换
extras/repo/pool/*.deb 存在           → 生成离线 APT 仓库索引 + GPG 签名
extras/keys/repo-signing.gpg 存在     → 导入到 squashfs 和目标系统的 trusted.gpg.d/
extras/drivers/MLNX_OFED*.tgz 存在   → 自动安装 Mellanox OFED（late-commands）
extras/drivers/NVIDIA*.run 存在       → 自动安装 userspace + 注册 firstboot 编译服务
extras/keys/authorized_keys 非空      → 自动写入 SSH 公钥到 ubuntu 用户
customize-squashfs.sh 存在            → build.sh 自动调用定制 squashfs
```

---

## Task 1：创建项目目录结构

**Files:**
- Create: `ubuntu-autoinstall/build.sh`
- Create: `ubuntu-autoinstall/user-data`
- Create: `ubuntu-autoinstall/meta-data`
- Create: `ubuntu-autoinstall/extras/scripts/post-install.sh`
- Create: `ubuntu-autoinstall/extras/scripts/install-mlnx.sh`
- Create: `ubuntu-autoinstall/extras/scripts/install-nvidia.sh`
- Create: `ubuntu-autoinstall/extras/keys/authorized_keys`
- Create: `ubuntu-autoinstall/extras/drivers/.gitkeep`

**Step 1: 创建目录树**

```bash
mkdir -p ubuntu-autoinstall/{extras/{scripts,keys,drivers,repo/pool,debs},docs}
touch ubuntu-autoinstall/meta-data
touch ubuntu-autoinstall/extras/keys/authorized_keys
touch ubuntu-autoinstall/extras/drivers/.gitkeep
touch ubuntu-autoinstall/extras/debs/.gitkeep
touch ubuntu-autoinstall/extras/repo/pool/.gitkeep
```

**Step 2: 验证结构**

```bash
find ubuntu-autoinstall -type f | sort
```

期望：列出所有文件路径，包括 `extras/repo/`、`extras/debs/`。

**Step 3: Commit**

```bash
git add ubuntu-autoinstall/
git commit -m "chore: init ubuntu-autoinstall project structure"
```

---

## Task 2：编写 user-data（autoinstall 配置）

**Files:**
- Create: `ubuntu-autoinstall/user-data`

```yaml
#cloud-config
autoinstall:
  version: 1

  apt:
    geoip: false
    preserve_sources_list: false
    primary:
      - arches: [amd64]
        uri: https://repo.huaweicloud.com/ubuntu
      - arches: [default]
        uri: http://ports.ubuntu.com/ubuntu-ports

  locale: en_US.UTF-8
  keyboard:
    layout: us
    variant: ''

  identity:
    hostname: ubuntu-server
    username: ubuntu
    # 用 openssl passwd -6 "yourpassword" 生成哈希
    password: "$6$j/6FKaGvOBawk54n$18J/U3APCJw5f/QiKGS/WPiCIVVbSz5tQ5gx8EODUfypNR.zjzYKLRtjfDOgLpd/W43zuHVioqELQOmEa34og1"

  ssh:
    install-server: true
    allow-pw: true
    authorized-keys: []

  storage:
    config:
      # 磁盘：自动选最大盘；固定磁盘改为 path: /dev/sda
      - type: disk
        id: disk0
        match:
          largest: true
        ptable: gpt
        wipe: superblock-recursive
        preserve: false
        grub_device: false

      # EFI 512M
      - type: partition
        id: part-efi
        device: disk0
        size: 512M
        flag: esp
        grub_device: true
        preserve: false

      # /boot 4G
      - type: partition
        id: part-boot
        device: disk0
        size: 4G
        preserve: false

      # / 剩余全部
      - type: partition
        id: part-root
        device: disk0
        size: -1
        preserve: false

      - {type: format, id: fmt-efi,  volume: part-efi,  fstype: fat32}
      - {type: format, id: fmt-boot, volume: part-boot, fstype: ext4}
      - {type: format, id: fmt-root, volume: part-root, fstype: ext4}

      - {type: mount, id: mnt-efi,  device: fmt-efi,  path: /boot/efi}
      - {type: mount, id: mnt-boot, device: fmt-boot, path: /boot}
      - {type: mount, id: mnt-root, device: fmt-root, path: /}

  network:
    version: 2
    ethernets:
      any-en:
        match: {name: "en*"}
        dhcp4: true
        optional: true
      any-eth:
        match: {name: "eth*"}
        dhcp4: true
        optional: true

  packages:
    - openssh-server
    - curl
    - wget
    - vim
    - net-tools
    - htop

  user-data:
    timezone: Asia/Shanghai
    package_update: false
    package_upgrade: false

  late-commands:
    # 复制附加内容到目标系统
    - mkdir -p /target/opt/extras
    - cp -r /cdrom/extras/scripts /target/opt/extras/
    - cp -r /cdrom/extras/drivers /target/opt/extras/
    - cp -r /cdrom/extras/keys    /target/opt/extras/
    - chmod +x /target/opt/extras/scripts/*.sh

    # ★ 配置离线 APT 仓库（GPG 签名）
    - test -d /cdrom/extras/repo/pool && cp -r /cdrom/extras/repo /target/opt/extras/
    - test -d /cdrom/extras/repo/pool && echo 'deb [signed-by=/etc/apt/trusted.gpg.d/repo-signing.gpg] file:///opt/extras/repo ./' > /target/etc/apt/sources.list.d/local-offline.list
    - test -f /cdrom/extras/keys/repo-signing.gpg && cp /cdrom/extras/keys/repo-signing.gpg /target/etc/apt/trusted.gpg.d/repo-signing.gpg

    # 写入 SSH 公钥
    - mkdir -p /target/home/ubuntu/.ssh
    - cp /cdrom/extras/keys/authorized_keys /target/home/ubuntu/.ssh/authorized_keys
    - chown -R 1000:1000 /target/home/ubuntu/.ssh
    - chmod 700 /target/home/ubuntu/.ssh
    - chmod 600 /target/home/ubuntu/.ssh/authorized_keys

    # 执行安装后主脚本
    - curtin in-target --target=/target -- bash /opt/extras/scripts/post-install.sh

    # sudo 免密
    - echo 'ubuntu ALL=(ALL) NOPASSWD:ALL' > /target/etc/sudoers.d/ubuntu
    - chmod 440 /target/etc/sudoers.d/ubuntu
```

**Step 1: 验证 YAML**

```bash
python3 -c "import yaml; yaml.safe_load(open('ubuntu-autoinstall/user-data'))" && echo "YAML OK"
```

期望：输出 `YAML OK`。

**Step 2: Commit**

```bash
git add ubuntu-autoinstall/user-data ubuntu-autoinstall/meta-data
git commit -m "feat: add autoinstall user-data with partition scheme and late-commands"
```

---

## Task 3：编写 post-install.sh

**Files:**
- Create: `ubuntu-autoinstall/extras/scripts/post-install.sh`

```bash
#!/bin/bash
# post-install.sh
# 由 autoinstall late-commands 通过 curtin in-target 调用
# 运行环境：目标系统内（已 chroot 至 /target）
set -euo pipefail

EXTRAS_DIR="/opt/extras"
LOG_FILE="/var/log/post-install.log"

log() { echo "[$(date '+%F %T')] $*" | tee -a "${LOG_FILE}"; }

log "===== post-install.sh 开始 ====="

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

# ── 在此追加其他自定义操作 ──
# log "示例：安装 Docker..."
# curl -fsSL https://get.docker.com | sh

log "===== post-install.sh 完成 ====="
```

**Step 1: 赋予可执行权限**

```bash
chmod +x ubuntu-autoinstall/extras/scripts/post-install.sh
```

**Step 2: Commit**

```bash
git add ubuntu-autoinstall/extras/scripts/post-install.sh
git commit -m "feat: add post-install.sh orchestrator"
```

---

## Task 4：编写 install-mlnx.sh

**Files:**
- Create: `ubuntu-autoinstall/extras/scripts/install-mlnx.sh`

**关键点：** 此脚本在目标机首次真实启动后运行（非 chroot），`uname -r` 返回真实内核，可直接编译。

```bash
#!/bin/bash
# install-mlnx.sh <mlnx_ofed.tgz>
set -euo pipefail
MLNX_TGZ="$1"
LOG="/var/log/mlnx-ofed-install.log"

echo "▸ Mellanox OFED：$(basename "${MLNX_TGZ}")"
echo "▸ 内核：$(uname -r)"

DEBIAN_FRONTEND=noninteractive apt-get install -y -q \
  python3 python3-distutils ethtool lsof \
  tk tcl libglib2.0-0 pciutils numactl libnuma1 \
  dkms build-essential "linux-headers-$(uname -r)" 2>&1 | tee -a "${LOG}"

TMPDIR=$(mktemp -d)
trap "rm -rf ${TMPDIR}" EXIT
tar xzf "${MLNX_TGZ}" -C "${TMPDIR}"

OFED_DIR=$(find "${TMPDIR}" -maxdepth 1 -type d -name "MLNX_OFED*" | head -1)
[[ -z "${OFED_DIR}" ]] && { echo "[ERROR] 未找到 MLNX_OFED 目录"; exit 1; }

mkdir -p /tmp/ofed-build
"${OFED_DIR}/mlnxofedinstall" \
  --without-fw-update \
  --add-kernel-support \
  --force \
  --tmpdir /tmp/ofed-build \
  2>&1 | tee -a "${LOG}"

echo "✓ Mellanox OFED 安装完成"
```

**Step 1: Commit**

```bash
chmod +x ubuntu-autoinstall/extras/scripts/install-mlnx.sh
git add ubuntu-autoinstall/extras/scripts/install-mlnx.sh
git commit -m "feat: add Mellanox OFED install script"
```

---

## Task 5：编写 install-nvidia.sh

**Files:**
- Create: `ubuntu-autoinstall/extras/scripts/install-nvidia.sh`

**策略：** `late-commands` 阶段（curtin in-target）只装 userspace；注册 `nvidia-driver-firstboot.service`，系统首次真实启动后自动编译内核模块。

```bash
#!/bin/bash
# install-nvidia.sh <nvidia.run>
set -euo pipefail
NVIDIA_RUN="$1"
LOG="/var/log/nvidia-install.log"

echo "▸ NVIDIA 驱动：$(basename "${NVIDIA_RUN}")"
chmod +x "${NVIDIA_RUN}"

# 禁用 Nouveau
cat > /etc/modprobe.d/blacklist-nouveau.conf << 'EOF'
blacklist nouveau
blacklist lbm-nouveau
options nouveau modeset=0
alias nouveau off
EOF
update-initramfs -u 2>/dev/null || true

# 仅安装 userspace（内核模块由 firstboot 服务编译）
"${NVIDIA_RUN}" \
  --no-kernel-module \
  --ui=none \
  --no-questions \
  --accept-license \
  --install-libglvnd \
  2>&1 | tee "${LOG}" \
|| echo "[WARN] userspace 安装有警告，见 ${LOG}"

# 保留 .run 文件供 firstboot 服务使用
cp "${NVIDIA_RUN}" /opt/nvidia-installer.run
chmod +x /opt/nvidia-installer.run

# 注册首次启动编译服务
cat > /etc/systemd/system/nvidia-driver-firstboot.service << 'SVCEOF'
[Unit]
Description=NVIDIA Kernel Module First-Boot Compilation
After=local-fs.target
ConditionPathExists=!/var/lib/.nvidia-compiled

[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutStartSec=1800
ExecStart=/bin/bash -c '\
  /opt/nvidia-installer.run \
    --silent --kernel-module-only --no-nouveau-check \
    2>&1 | tee /var/log/nvidia-firstboot.log \
  && depmod -a \
  && touch /var/lib/.nvidia-compiled \
  || echo "编译失败，见 /var/log/nvidia-firstboot.log"'

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl enable nvidia-driver-firstboot.service
echo "✓ NVIDIA userspace 已安装，内核模块将在首次重启后自动编译"
```

**Step 1: Commit**

```bash
chmod +x ubuntu-autoinstall/extras/scripts/install-nvidia.sh
git add ubuntu-autoinstall/extras/scripts/install-nvidia.sh
git commit -m "feat: add NVIDIA install script with firstboot kernel module service"
```

---

## Task 6：创建本地 APT 仓库 + GPG 签名（新增）

**Files:**
- Create: `ubuntu-autoinstall/build-repo.sh`

**说明：** 此脚本在构建机（非目标机）运行，将指定的 deb 包打包为带 GPG 签名的本地 APT 仓库。构建机需要能访问网络下载依赖包，或手动将 deb 包放入 `extras/repo/pool/`。

```bash
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
for cmd in dpkg-scanpackages apt-ftparchive gpg; do
  command -v "$cmd" &>/dev/null || error "缺少工具：$cmd（apt install dpkg-dev apt-utils gnupg）"
done

# ──── 第 2 步：生成 GPG 密钥（如不存在） ────
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
```

**Step 1: 运行构建仓库**

```bash
chmod +x ubuntu-autoinstall/build-repo.sh
# 手动将需要的 deb 包放入 extras/repo/pool/（或让脚本自动下载）
bash ubuntu-autoinstall/build-repo.sh
```

**Step 2: 验证仓库**

```bash
# 检查索引
zcat ubuntu-autoinstall/extras/repo/Packages.gz | head -20
# 检查签名
gpg --verify ubuntu-autoinstall/extras/repo/Release.gpg ubuntu-autoinstall/extras/repo/Release
```

**Step 3: Commit**

```bash
git add ubuntu-autoinstall/build-repo.sh ubuntu-autoinstall/extras/repo/ ubuntu-autoinstall/extras/keys/repo-signing.gpg
git commit -m "feat: add local APT repo builder with GPG signing"
```

---

## Task 7：编写 customize-squashfs.sh（squashfs 定制脚本，新增）

**Files:**
- Create: `ubuntu-autoinstall/customize-squashfs.sh`

**说明：** 此脚本由 build.sh 在 ISO 解包后调用，负责解包 squashfs → chroot 安装软件 → 替换特定包 → 重新打包。需要 root 权限。

```bash
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

# ──── 第 3 步：导入 GPG 公钥 ────
step "导入 GPG 公钥"
if [[ -f "${SCRIPT_DIR}/extras/keys/repo-signing.gpg" ]]; then
  cp "${SCRIPT_DIR}/extras/keys/repo-signing.gpg" \
     "${SQUASHFS_ROOT}/etc/apt/trusted.gpg.d/repo-signing.gpg"
  ok "GPG 公钥已导入"
else
  warn "未发现 repo-signing.gpg，跳过"
fi

# ──── 第 4 步：chroot 安装预装包 ────
step "安装预装软件包"

# 预装包列表（可根据需要修改）
PREINSTALL_PACKAGES=(
  build-essential gcc g++ make cmake
  dkms linux-headers-generic
  python3 python3-dev
  curl wget vim htop net-tools
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
```

**Step 1: 验证语法**

```bash
bash -n ubuntu-autoinstall/customize-squashfs.sh && echo "语法正确"
```

**Step 2: Commit**

```bash
chmod +x ubuntu-autoinstall/customize-squashfs.sh
git add ubuntu-autoinstall/customize-squashfs.sh
git commit -m "feat: add squashfs customization script (preinstall packages + GPG)"
```

---

## Task 8：编写 build.sh（主构建脚本）

**Files:**
- Create: `ubuntu-autoinstall/build.sh`

```bash
#!/bin/bash
# build.sh — Ubuntu 22.04 Subiquity AutoInstall ISO 构建脚本
set -euo pipefail

# ════════════════ 配置区 ════════════════
UBUNTU_ISO_PATH="/opt/ubuntu-22.04-live-server-amd64.iso"
BUILD_DATE="$(date '+%Y%m%d')"
OUTPUT_ISO="/home/isobuild/ubuntu-22.04-autoinstall-${BUILD_DATE}.iso"
WORK_DIR="/tmp/iso-build-work"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# ════════════════════════════════════════

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
step()  { echo -e "\n${BOLD}${BLUE}──── $* ────${NC}"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
ok()    { echo -e "${GREEN}[OK]${NC}   $*"; }

[[ $EUID -ne 0 ]] && error "请以 root 权限运行：sudo bash $0"

# ──── 第 1 步：依赖检查 ────
step "依赖检查"
MISSING=()
for cmd in xorriso python3 unsquashfs mksquashfs dpkg-scanpackages gpg; do
  if command -v "$cmd" &>/dev/null; then
    ok "$cmd"
  else
    warn "$cmd 缺失"
    MISSING+=("$cmd")
  fi
done
if [[ ${#MISSING[@]} -gt 0 ]]; then
  info "安装缺失工具：${MISSING[*]}"
  apt-get update -q && apt-get install -y -q "${MISSING[@]}"
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
[[ ${AVAIL} -lt 5 ]] && error "输出目录磁盘空间不足（需 5GB，现有 ${AVAIL}GB）"
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

# ──── 第 5 步：注入 autoinstall 配置 ────
step "注入 autoinstall 配置"
mkdir -p "${WORK_DIR}/autoinstall"
cp "${SCRIPT_DIR}/user-data" "${WORK_DIR}/autoinstall/user-data"
cp "${SCRIPT_DIR}/meta-data" "${WORK_DIR}/autoinstall/meta-data"
ok "autoinstall/ 注入完成"

# ──── 第 6 步：注入 extras ────
step "注入 extras（脚本 / 驱动 / 密钥 / 离线仓库）"
cp -r "${SCRIPT_DIR}/extras" "${WORK_DIR}/extras"
chmod +x "${WORK_DIR}/extras/scripts/"*.sh 2>/dev/null || true

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

# ──── 第 8 步：封装 ISO ────
step "封装 ISO"
rm -f "${OUTPUT_ISO}"

MBR_IMG="${WORK_DIR}/boot/grub/i386-pc/boot_hybrid.img"
EFI_IMG="${WORK_DIR}/boot/grub/efi.img"

if [[ -f "${MBR_IMG}" && -f "${EFI_IMG}" ]]; then
  info "UEFI + Legacy BIOS 双模式"
  xorriso -as mkisofs \
    -r -V "Ubuntu-2204-AutoInstall" \
    -o "${OUTPUT_ISO}" \
    --grub2-mbr "${MBR_IMG}" \
    -partition_offset 16 --mbr-force-bootable \
    -append_partition 2 28732ac11ff8d211ba4b00a0c93ec93b "${EFI_IMG}" \
    -appended_part_as_gpt \
    -iso_mbr_part_type a2a0d0ebe5b9334487c068b6b72699c7 \
    -c '/boot/grub/boot.cat' \
    -b '/boot/grub/i386-pc/eltorito.img' \
    -no-emul-boot -boot-load-size 4 -boot-info-table --grub2-boot-info \
    -eltorito-alt-boot \
    -e '--interval:appended_partition_2:::' \
    -no-emul-boot \
    "${WORK_DIR}" 2>&1 | tail -5
else
  info "GRUB EFI 单模式"
  xorriso -as mkisofs \
    -r -V "Ubuntu-2204-AutoInstall" \
    -o "${OUTPUT_ISO}" \
    -c '/boot/grub/boot.cat' \
    -b '/boot/grub/i386-pc/eltorito.img' \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    "${WORK_DIR}" 2>&1 | tail -5
fi

rm -rf "${WORK_DIR}"

echo ""
echo -e "${BOLD}${GREEN}"
echo "  ╔══════════════════════════════════════════════════╗"
echo "  ║            ✅  ISO 构建成功！                    ║"
echo "  ╚══════════════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "  输出文件：${OUTPUT_ISO}（$(du -sh "${OUTPUT_ISO}" | cut -f1)）"
echo ""
echo -e "  刻录 U 盘：${BOLD}sudo dd if=${OUTPUT_ISO} of=/dev/sdX bs=4M status=progress${NC}"
echo ""
echo -e "  ${RED}${BOLD}⚠  ISO 启动后将自动安装，目标磁盘数据将被清空！${NC}"
echo ""
```

**Step 1: 语法检查**

```bash
bash -n ubuntu-autoinstall/build.sh && echo "语法正确"
```

**Step 2: Commit**

```bash
chmod +x ubuntu-autoinstall/build.sh
git add ubuntu-autoinstall/build.sh
git commit -m "feat: add build.sh with squashfs customization, repo injection, ISO repack"
```

---

## Task 9：准备运行材料 & 测试

**Step 1: 写入 SSH 公钥**

```bash
cat ~/.ssh/id_rsa.pub >> ubuntu-autoinstall/extras/keys/authorized_keys
```

**Step 2: 放入驱动文件（可选）**

```bash
cp /opt/drivers/MLNX_OFED_LINUX-*.tgz ubuntu-autoinstall/extras/drivers/
cp /opt/drivers/NVIDIA-Linux-x86_64-*.run ubuntu-autoinstall/extras/drivers/
```

**Step 3: 放入特定版本 deb 包（可选）**

```bash
# 将需要预装到 squashfs 的特定版本 deb 包放入 extras/debs/
cp /opt/custom-drivers/*.deb ubuntu-autoinstall/extras/debs/
```

**Step 4: 构建本地 APT 仓库**

```bash
# 如果需要离线仓库，先构建仓库（需联网下载包）
bash ubuntu-autoinstall/build-repo.sh

# 或手动将 deb 包放入 extras/repo/pool/ 后再运行
cp /opt/offline-packages/*.deb ubuntu-autoinstall/extras/repo/pool/
bash ubuntu-autoinstall/build-repo.sh
```

**Step 5: 执行 ISO 构建**

```bash
sudo bash ubuntu-autoinstall/build.sh
```

期望末尾输出：
```
✅  ISO 构建成功！
输出文件：/home/isobuild/ubuntu-22.04-autoinstall.iso
```

**Step 6: QEMU 虚拟机测试**

```bash
# 安装测试工具
sudo apt install -y qemu-system-x86 ovmf

# 创建 20GB 测试磁盘
qemu-img create -f qcow2 /tmp/test-disk.qcow2 20G

# 启动虚拟机
sudo qemu-system-x86_64 \
  -m 4096 -smp 2 \
  -bios /usr/share/ovmf/OVMF.fd \
  -drive file=/tmp/test-disk.qcow2,format=qcow2 \
  -cdrom /home/isobuild/ubuntu-22.04-autoinstall.iso \
  -boot d -vnc :1
```

**Step 7: 安装后验证**

```bash
ssh ubuntu@<IP>

# ── 基础验证 ──
lsblk                           # 验证分区：EFI + /boot + /
cat ~/.ssh/authorized_keys       # 验证 SSH 公钥
cat /var/log/post-install.log    # 查看安装后脚本日志

# ── squashfs 预装包验证 ──
dpkg -l | grep build-essential   # 验证编译工具链已安装
gcc --version                    # 验证 gcc 可用
make --version                   # 验证 make 可用

# ── 离线 APT 仓库验证 ──
cat /etc/apt/sources.list.d/local-offline.list  # 验证仓库配置
apt-get update                   # 验证仓库索引可读取
apt-cache policy <package>       # 验证特定包来源为本地仓库

# ── GPG 签名验证 ──
apt-key list 2>/dev/null || gpg --list-keys --keyring /etc/apt/trusted.gpg.d/repo-signing.gpg

# ── 驱动验证（如有） ──
nvidia-smi                       # 验证 NVIDIA
ibv_devinfo                      # 验证 Mellanox

# ── 离线安装测试 ──
# 断开网络后测试
sudo ip link set eth0 down       # 模拟断网
apt install -y <package>         # 应能从本地仓库安装
```

---

## 扩展点

| 需求 | 修改位置 | 方法 |
|------|---------|------|
| 增加 squashfs 预装包 | `customize-squashfs.sh → PREINSTALL_PACKAGES` | 追加包名 |
| 增加离线仓库包 | `build-repo.sh → OFFLINE_PACKAGES` 或手动放入 `extras/repo/pool/` | 追加包名或 deb 文件 |
| 替换特定版本包 | `extras/debs/` | 放入 deb 文件 |
| 更换 GPG 密钥 | `build-repo.sh → GPG_NAME` | 修改密钥信息或导入已有密钥 |
| 添加第三方 APT 源 | `customize-squashfs.sh` | 在 chroot 中添加源 + 密钥 |
| 执行自定义脚本 | `extras/scripts/post-install.sh` | 追加命令 |
| 多条 SSH 公钥 | `extras/keys/authorized_keys` | 每行一条 |
| 固定目标磁盘 | `user-data → storage.config[0].match` | 改为 `path: /dev/sda` |
| 固定 IP 配置 | `user-data → network` | 修改 netplan 段 |
| 安装 Docker | `post-install.sh` | 追加安装命令 |
| PXE 网络安装 | `build.sh + GRUB` | 改 GRUB 参数为 HTTP 数据源 |
