# Ubuntu 22.04 AutoInstall ISO Build System

基于 Ubuntu 22.04 Server 官方 ISO，构建定制化全自动安装镜像。

## 特性

- **定制 squashfs** — 预装编译工具链、驱动依赖，安装后即可用
- **全自动安装** — Subiquity autoinstall，无人值守
- **离线驱动支持** — Mellanox OFED / NVIDIA GPU 驱动离线安装
- **可选离线仓库** — 本地 APT 仓库 + GPG 签名（需要指定内核版本时启用）
- **固定内核版本** — 支持通过 `extras/config/kernel.env` 指定目标内核版本，并在安装阶段离线安装与可选锁定

## 项目结构

```
ubuntu-autoinstall/
├── build.sh                  # 主构建脚本（唯一入口）
├── customize-squashfs.sh     # squashfs 定制（build.sh 自动调用）
├── build-repo.sh             # 本地 APT 仓库构建（可选，暂不需要）
├── user-data                 # autoinstall 配置
├── meta-data                 # cloud-init 元数据
└── extras/
    ├── scripts/
    │   ├── post-install.sh   # 安装后主脚本
    │   ├── install-mlnx.sh   # Mellanox OFED 安装
    │   └── install-nvidia.sh # NVIDIA 驱动安装
    ├── config/
    │   └── kernel.env        # 固定内核版本 / 离线仓库配置
    ├── keys/
    │   └── authorized_keys   # SSH 公钥（每行一条）
    ├── drivers/              # 驱动文件（手动放入）
    ├── debs/                 # 特定版本 deb 包（手动放入，可选）
    └── repo/                 # 离线 APT 仓库（build-repo.sh 生成，可选）
```

## 快速开始

### 1. 环境要求

- Ubuntu 构建机（需要 root 权限）
- 已下载 Ubuntu 22.04.5 Server ISO 到 `/opt/ubuntu-22.04.5-live-server-amd64.iso`

安装构建依赖：

```bash
sudo apt install -y xorriso squashfs-tools python3
```

### 2. 准备材料

```bash
# SSH 公钥（安装后可免密登录）
cat ~/.ssh/id_rsa.pub >> ubuntu-autoinstall/extras/keys/authorized_keys

# Mellanox OFED 驱动（可选）
cp MLNX_OFED_LINUX-*.tgz ubuntu-autoinstall/extras/drivers/

# NVIDIA 驱动（可选）
cp NVIDIA-Linux-x86_64-*.run ubuntu-autoinstall/extras/drivers/

# 特定版本 deb 包（可选，会在 squashfs 中 dpkg -i 安装）
cp custom-package.deb ubuntu-autoinstall/extras/debs/
```

### 3. 构建 ISO

```bash
sudo bash ubuntu-autoinstall/build.sh
```

构建流程：

1. 依赖检查
2. 检查本地 Ubuntu ISO
3. 解包 ISO
4. **定制 squashfs**（chroot 安装编译工具链 + 驱动依赖 + 特定 deb 包）
5. 注入 autoinstall 配置
6. 注入 extras（脚本 / 驱动 / 密钥）
7. 修改 GRUB 引导参数
8. 封装 ISO（UEFI + Legacy BIOS 双模式）

输出：`/home/isobuild/ubuntu-22.04-autoinstall-YYYYMMDD.iso`

### 指定固定内核版本（可选）

编辑 `ubuntu-autoinstall/extras/config/kernel.env`：

```bash
KERNEL_VERSION="5.15.0-164"
KERNEL_FLAVOR="generic"
INSTALL_MODE="repo"
KERNEL_HOLD="true"
```

推荐离线方式（`repo` 模式）：

```bash
# 1. 下载或手动准备目标内核 deb
./scripts/download-kernel.sh 5.15.0-164 ./kernel-debs

# 2. 放入本地离线仓库
mkdir -p ubuntu-autoinstall/extras/repo/pool
cp ./kernel-debs/*.deb ubuntu-autoinstall/extras/repo/pool/

# 3. 生成离线仓库索引与签名
bash ubuntu-autoinstall/build-repo.sh

# 4. 构建 ISO
sudo bash ubuntu-autoinstall/build.sh
```

安装阶段会自动：
- 复制 `/cdrom/extras` 到目标机 `/opt/extras`
- 运行 `post-install.sh`
- 读取 `extras/config/kernel.env`
- 按 `INSTALL_MODE=deb|repo|auto` 选择安装方式
- 安装指定内核并按需 `apt-mark hold`

如果你想先走更直接的 `deb` 模式：

```bash
KERNEL_VERSION="5.15.0-164"
INSTALL_MODE="deb"
KERNEL_HOLD="true"
```

然后把对应内核包直接放入：

```bash
ubuntu-autoinstall/extras/debs/
```

### 4. 刻录 U 盘

```bash
sudo dd if=/home/isobuild/ubuntu-22.04-autoinstall-YYYYMMDD.iso of=/dev/sdX bs=4M status=progress
```

> **警告：ISO 启动后将自动安装，目标磁盘 /dev/sda 数据将被清空！**

### 5. 安装验证

```bash
ssh ubuntu@<IP>

# 验证分区
lsblk

# 验证编译工具链
gcc --version
make --version

# 验证驱动（如有）
nvidia-smi
ibv_devinfo

# 查看安装日志
cat /var/log/post-install.log
```

## 配置说明

### user-data

| 配置项 | 默认值 | 说明 |
|--------|--------|------|
| 目标磁盘 | `/dev/sda` | 修改 `storage.config` 中的 `path` |
| 分区方案 | EFI(512M) + /boot(4G) + /(剩余) | 无 swap |
| 用户名 | `ubuntu` | 修改 `identity.username` |
| 密码 | 见文件内哈希 | 用 `openssl passwd -6 "新密码"` 生成替换 |
| APT 源 | 华为云镜像 | 修改 `apt.primary[0].uri` |
| 时区 | Asia/Shanghai | 修改 `user-data.timezone` |
| sudo | 免密 | 通过 `write_files` 配置 |

### squashfs 预装包

编辑 `customize-squashfs.sh` 中的 `PREINSTALL_PACKAGES` 数组：

```bash
PREINSTALL_PACKAGES=(
  # 基础工具
  openssh-server curl wget vim htop net-tools
  # 编译工具链
  build-essential gcc g++ make cmake dkms linux-headers-generic
  # Mellanox OFED 依赖
  python3 python3-dev python3-distutils ethtool lsof pciutils ...
  # NVIDIA 依赖
  pkg-config libglvnd-dev kmod initramfs-tools
  # 在此追加更多包
)
```

### 驱动安装逻辑

| 条件 | 触发动作 |
|------|---------|
| `extras/drivers/MLNX_OFED*.tgz` 存在 | `post-install.sh` 调用 `install-mlnx.sh` |
| `extras/drivers/NVIDIA*.run` 存在 | `post-install.sh` 调用 `install-nvidia.sh`，注册 firstboot 服务 |
| `extras/debs/*.deb` 存在 | squashfs 定制时 `dpkg -i` 安装 |

NVIDIA 驱动采用两阶段安装：
1. **安装时**：仅安装 userspace，禁用 Nouveau
2. **首次启动**：`nvidia-driver-firstboot.service` 自动编译内核模块

## 高级功能（可选）

### 本地离线 APT 仓库

当需要指定内核版本或添加自定义仓库时：

```bash
# 将 deb 包放入 repo/pool/
cp *.deb ubuntu-autoinstall/extras/repo/pool/

# 构建仓库索引 + GPG 签名
bash ubuntu-autoinstall/build-repo.sh
```

`late-commands` 和 `post-install.sh` 已经会自动把 `/cdrom/extras` 接到目标系统；当配置了 `KERNEL_VERSION` 时，会按 `INSTALL_MODE` 选择 `extras/repo/` 或 `extras/debs/` 作为固定内核来源。

### 文档

- 固定内核版本与离线安装完整说明：`ubuntu-autoinstall/docs/offline-kernel-versioning.md`

### QEMU 测试

```bash
sudo apt install -y qemu-system-x86 ovmf
qemu-img create -f qcow2 /tmp/test-disk.qcow2 20G

sudo qemu-system-x86_64 \
  -m 4096 -smp 2 \
  -bios /usr/share/ovmf/OVMF.fd \
  -drive file=/tmp/test-disk.qcow2,format=qcow2 \
  -cdrom /home/isobuild/ubuntu-22.04-autoinstall-YYYYMMDD.iso \
  -boot d -vnc :1
```

## 修改 ISO 源路径

编辑 `build.sh` 顶部配置区：

```bash
UBUNTU_ISO_PATH="/opt/ubuntu-22.04.5-live-server-amd64.iso"  # 源 ISO 路径
OUTPUT_ISO="/home/isobuild/ubuntu-22.04-autoinstall-${BUILD_DATE}.iso"  # 输出路径
```

也可以用环境变量覆盖而不改脚本：

```bash
sudo UBUNTU_ISO_PATH=/path/to/ubuntu-22.04.5-live-server-amd64.iso \
     OUTPUT_ISO=/path/to/output.iso \
     bash ubuntu-autoinstall/build.sh
```
