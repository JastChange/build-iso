# 使用文档

本文说明如何准备材料、配置自动安装、构建 ISO、安装系统并验证结果。

## 1. 构建环境

建议使用 Ubuntu 22.04/24.04 构建机，并准备 root 权限。

```bash
sudo apt-get update
sudo apt-get install -y xorriso squashfs-tools python3 dpkg-dev apt-utils gnupg
```

默认源 ISO 路径：

```bash
/opt/ubuntu-22.04.5-live-server-amd64.iso
```

如果源 ISO 或输出位置不同，可以通过环境变量覆盖：

```bash
sudo UBUNTU_ISO_PATH=/path/to/ubuntu.iso \
     OUTPUT_ISO=/path/to/ubuntu-autoinstall.iso \
     WORK_DIR=/tmp/iso-build-work \
     bash ubuntu-autoinstall/build.sh
```

## 2. 配置自动安装

主要配置文件是 `ubuntu-autoinstall/user-data`。

常改字段：

| 配置 | 默认值 | 说明 |
|------|--------|------|
| 目标磁盘 | `/dev/sda` | 修改 `storage.config` 中磁盘 `path` |
| 分区 | EFI 512M、`/boot` 4G、`/` 剩余空间 | 全部由 `user-data` 控制 |
| 用户名 | `ubuntu` | 修改 `identity.username` |
| 密码 | 文件内 SHA-512 哈希 | 用 `openssl passwd -6 "密码"` 生成 |
| APT 源 | 华为云 Ubuntu 源 | 修改 `apt.primary` |
| 时区 | `Asia/Shanghai` | 修改 `user-data.timezone` |

SSH 公钥放入：

```bash
ubuntu-autoinstall/extras/keys/authorized_keys
```

构建时 `build.sh` 会把这里的公钥注入到 ISO 内的 `autoinstall/user-data`。

## 3. 配置预装工具

编辑：

```bash
ubuntu-autoinstall/extras/config/packages.list
```

每行一个 apt 包名，空行和 `#` 注释会被忽略。构建时 `customize-squashfs.sh` 会在 chroot 中安装这些包，使目标系统安装完成后直接带有这些工具。

示例：

```text
openssh-server
curl
vim
build-essential
dkms
linux-headers-generic
```

## 4. 指定内核版本

编辑：

```bash
ubuntu-autoinstall/extras/config/kernel.env
```

示例：

```bash
KERNEL_VERSION="5.15.0-164"
KERNEL_FLAVOR="generic"
INSTALL_MODE="repo"
KERNEL_HOLD="true"
```

`INSTALL_MODE` 支持：

| 模式 | 说明 |
|------|------|
| `repo` | 只从 `extras/repo` 本地离线仓库安装 |
| `deb` | 只从 `extras/debs` 中直接 `dpkg -i` 安装 |
| `auto` | 先尝试 repo，再尝试 deb，最后回退系统 APT 源 |

推荐离线 repo 模式：

```bash
./scripts/download-kernel.sh 5.15.0-164 ./kernel-debs
mkdir -p ubuntu-autoinstall/extras/repo/pool
cp ./kernel-debs/*.deb ubuntu-autoinstall/extras/repo/pool/
bash ubuntu-autoinstall/build-repo.sh
```

然后构建 ISO：

```bash
sudo bash ubuntu-autoinstall/build.sh
```

## 5. 配置首次开机任务

首次开机配置文件：

```bash
ubuntu-autoinstall/extras/config/firstboot.env
```

可配置项：

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `FIRSTBOOT_REBOOT` | `true` | 首次开机任务完成后是否自动重启 |
| `CLEANUP_EXTRAS` | `true` | 是否删除 `/opt/extras` |
| `DRIVER_FAILURE_POLICY` | `continue` | 驱动失败后继续还是终止，支持 `continue`/`fail` |
| `FIRSTBOOT_DEBUG` | `true` | 是否写入 firstboot 和驱动安装 trace |
| `DRIVER_OFFLINE_MODE` | `true` | 驱动首次开机安装是否强制离线；为 `true` 时不会执行 `apt-get update/install` |
| `DEBUG_DIR` | `/var/log/ubuntu-autoinstall-debug` | 调试日志目录 |
| `MLNX_INSTALL_PROFILE` | `basic` | Mellanox OFED 安装范围，支持 `basic`/`hpc`/`all`/`dpdk`/`ovs-dpdk`/`vma`/`xlio`/`guest`/`hypervisor`/`bluefield`/`none` |
| `RETAIN_ON_DRIVER_FAILURE` | `true` | 驱动失败时保留 `/opt/extras` 和驱动包 |
| `REBOOT_ON_DRIVER_FAILURE` | `false` | 驱动失败时是否仍自动重启 |
| `MARK_DONE_ON_DRIVER_FAILURE` | `false` | 驱动失败时是否仍写入 `firstboot.done` |
| `KEEP_SERVICE_ON_DRIVER_FAILURE` | `true` | 驱动失败时是否保留 `iso-firstboot.service` |

## 6. 放入驱动

Mellanox OFED：

```bash
cp MLNX_OFED_LINUX-*.tgz ubuntu-autoinstall/extras/drivers/
# 或
cp MLNX_OFED_LINUX-*.iso ubuntu-autoinstall/extras/drivers/
```

默认 `MLNX_INSTALL_PROFILE=basic`，只安装基础网卡/RDMA 功能。安装命令会固定追加 `--add-kernel-support --skip-distro-check --force --enable-opensm`，用于当前运行内核构建支持包并启用 OpenSM。需要 OpenMPI、UCX、SHARP、HCOLL 等 HPC 组件时再改成 `hpc` 或 `all`。

NVIDIA：

```bash
cp NVIDIA-Linux-x86_64-*.run ubuntu-autoinstall/extras/drivers/
```

NVIDIA 安装命令固定使用 `-s --dkms --no-questions --accept-license --no-nouveau-check --install-libglvnd`，通过 DKMS 管理内核模块。

驱动不会在构建阶段安装，也不会在安装器 chroot 阶段编译。它们会在目标系统第一次真实启动后由 `iso-firstboot.service` 调用 `firstboot.sh` 安装。

默认 `DRIVER_OFFLINE_MODE=true`，首次开机安装 NVIDIA / Mellanox 驱动时不会联网安装依赖。如果日志中出现 `缺失依赖`，需要把对应包名加入 `ubuntu-autoinstall/extras/config/packages.list`，或放入 `extras/repo` 后重新构建 ISO。当前默认预装列表已经包含 NVIDIA 编译依赖、Mellanox OFED 基础依赖以及 `bison`、`swig`、`flex`、`graphviz`、`gfortran`、`libgfortran5`。

## 7. 构建 ISO

```bash
sudo bash ubuntu-autoinstall/build.sh
```

默认输出：

```bash
/home/isobuild/ubuntu-22.04-autoinstall-YYYYMMDD.iso
```

构建脚本会执行：

1. 检查依赖和源 ISO。
2. 解包 ISO 到工作目录。
3. 定制 squashfs 并安装 `packages.list` 中的软件。
4. 注入 `autoinstall/` 和 `extras/`。
5. 修改 GRUB 自动安装入口。
6. 使用 `xorriso` 重新封装 UEFI + Legacy BIOS 双模式 ISO。

## 8. 安装与验证

刻录 U 盘前务必确认目标盘。自动安装会清空 `user-data` 中指定磁盘。

安装完成并首次开机任务结束后，验证：

```bash
ssh ubuntu@<服务器IP>
uname -r
lsblk
dpkg -l | grep '^ii  linux-'
apt-mark showhold | grep '^linux-' || true
cat /var/log/post-install.log
cat /var/log/ubuntu-autoinstall-firstboot.log
ls -lah /var/log/ubuntu-autoinstall-debug/
```

驱动验证：

```bash
nvidia-smi
ibv_devinfo
```

如果 `CLEANUP_EXTRAS=true`，首次开机完成后 `/opt/extras` 会被删除；日志保留在 `/var/log/`。

## 9. 驱动失败排查

驱动失败时默认不自动重启、不删除 `/opt/extras`、不写入 `firstboot.done`，并保留 `iso-firstboot.service`。常用日志：

```bash
cat /var/log/ubuntu-autoinstall-firstboot.log
cat /var/log/mlnx-ofed-install.log
cat /var/log/nvidia-install.log
cat /var/lib/ubuntu-autoinstall/driver-failures.log
ls -lah /var/log/ubuntu-autoinstall-debug/
```

调试目录中的关键文件：

| 文件或目录 | 说明 |
|------------|------|
| `firstboot-system.txt` | 首次开机环境、内核、驱动包、PCI 设备、DKMS 状态 |
| `firstboot.trace` | `firstboot.sh` shell trace |
| `mlnx-ofed-system.txt` | Mellanox OFED 安装前环境快照，会标出 OFED 包与系统版本是否匹配 |
| `mlnx-ofed.trace` | Mellanox 安装脚本 shell trace |
| `mlnx-ofed.stdout.log` | Mellanox 安装器标准输出 |
| `mlnx-ofed-artifacts/` | OFED 安装器日志、DKMS 状态、dmesg 等归档 |
| `mlnx-ofed-artifacts/failure-summary.txt` | OFED 失败摘要，包含 `*.debinstall.log` 尾部、`dpkg --audit`、`apt-get check` |
| `nvidia-system.txt` | NVIDIA 安装前环境快照，包含 Secure Boot、nouveau、GPU PCI 信息 |
| `nvidia.trace` | NVIDIA 安装脚本 shell trace |
| `nvidia.stdout.log` | NVIDIA 安装器标准输出 |
| `nvidia-artifacts/` | `nvidia-installer.log`、DKMS 状态、dmesg 等归档 |

排查后可手动重跑：

```bash
sudo EXTRAS_DIR=/opt/extras DEBUG_DIR=/var/log/ubuntu-autoinstall-debug \
  bash /opt/extras/scripts/firstboot.sh
```

如果确认失败原因已经修复，并希望恢复完成态：

```bash
sudo systemctl disable iso-firstboot.service
sudo rm -f /etc/systemd/system/multi-user.target.wants/iso-firstboot.service
sudo rm -f /etc/systemd/system/iso-firstboot.service
sudo systemctl daemon-reload
```
