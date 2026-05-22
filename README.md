# Ubuntu 自动安装 ISO 构建项目

本项目用于基于 Ubuntu Server Live ISO 构建无人值守安装镜像。镜像启动后通过 Subiquity autoinstall 自动分区、创建用户、写入 SSH 密钥、安装指定工具，并可在安装阶段固定内核版本；需要依赖真实运行内核的驱动会在目标系统首次开机后安装。最终验收脚本通过后才会清理残留文件并按配置重启服务器。

## 当前能力

| 能力 | 状态 | 实现位置 |
|------|------|----------|
| Ubuntu autoinstall 自动安装 | 已实现 | `ubuntu-autoinstall/user-data` |
| 分区、用户、密码、SSH 密钥由 user-data 控制 | 已实现 | `user-data`、`build.sh` |
| 构建时预装工具包 | 已实现 | `extras/config/packages.list`、`customize-squashfs.sh` |
| 指定版本内核安装和锁定 | 已实现 | `extras/config/kernel.env`、`post-install.sh` |
| 本地离线 APT 仓库 | 已实现 | `build-repo.sh`、`extras/repo/` |
| Mellanox OFED / NVIDIA 驱动首次开机离线安装 | 已实现 | `firstboot.sh`、`install-mlnx.sh`、`install-nvidia.sh` |
| 最终验收通过后清理残留并重启 | 已实现 | `verify-install.sh`、`firstboot.sh` |
| 使用文档、设计文档、审查文档 | 已补全 | `docs/` |

## 快速开始

在 Ubuntu 构建机上准备依赖：

```bash
sudo apt-get update
sudo apt-get install -y xorriso squashfs-tools python3 dpkg-dev apt-utils gnupg
```

准备官方 Ubuntu Server ISO，默认路径为：

```bash
/opt/ubuntu-22.04.5-live-server-amd64.iso
```

按需放入材料：

```bash
# SSH 公钥
cat ~/.ssh/id_rsa.pub >> ubuntu-autoinstall/extras/keys/authorized_keys

# Mellanox OFED 驱动，可选，支持 .tgz 或 .iso
cp MLNX_OFED_LINUX-*.{tgz,iso} ubuntu-autoinstall/extras/drivers/

# NVIDIA 驱动，可选
cp NVIDIA-Linux-x86_64-*.run ubuntu-autoinstall/extras/drivers/
```

构建 ISO：

```bash
sudo bash ubuntu-autoinstall/build.sh
```

也可以通过环境变量覆盖输入和输出路径：

```bash
sudo UBUNTU_ISO_PATH=/path/to/ubuntu.iso \
     OUTPUT_ISO=/path/to/output.iso \
     bash ubuntu-autoinstall/build.sh
```

## 指定内核版本

编辑 `ubuntu-autoinstall/extras/config/kernel.env`：

```bash
KERNEL_VERSION="5.15.0-164"
KERNEL_FLAVOR="generic"
INSTALL_MODE="repo"
KERNEL_HOLD="true"
```

推荐使用本地 repo 模式：

```bash
./scripts/download-kernel.sh 5.15.0-164 ./kernel-debs
mkdir -p ubuntu-autoinstall/extras/repo/pool
cp ./kernel-debs/*.deb ubuntu-autoinstall/extras/repo/pool/
bash ubuntu-autoinstall/build-repo.sh
sudo bash ubuntu-autoinstall/build.sh
```

## 安装链路

1. ISO 启动后通过 GRUB 参数加载 `/cdrom/autoinstall/user-data`。
2. Subiquity 按 `user-data` 自动分区、创建用户并安装系统。
3. `late-commands` 复制 `/cdrom/extras` 到目标机 `/opt/extras`。
4. `post-install.sh` 在目标系统 chroot 内安装指定内核、执行 `apt-mark hold`，写入 GRUB 默认内核，并注册 `iso-firstboot.service`。
5. 目标系统第一次真实启动后，`firstboot.sh` 先确认 `uname -r` 等于目标内核，再安装 Mellanox / NVIDIA 驱动。
6. `verify-install.sh` 执行最终验收；验收通过后才清理 `/opt/extras`、禁用服务，并根据 `firstboot.env` 自动重启。

如果内核不匹配、驱动安装失败或最终验收失败，默认保留 `/opt/extras` 和 `iso-firstboot.service`，不自动重启，便于现场排查后重跑。

驱动安装默认强制离线：`firstboot.env` 中 `DRIVER_OFFLINE_MODE=true` 时，目标机首次开机阶段不会执行 `apt-get update/install`。驱动依赖需要在构建 ISO 时通过 `extras/config/packages.list` 或 `extras/repo` 预装进系统。

## 文档

- 使用文档：`docs/usage.md`
- 设计文档：`docs/design.md`
- 现状审查：`docs/review.md`
- 固定内核说明：`ubuntu-autoinstall/docs/offline-kernel-versioning.md`

## 验证

本仓库提供轻量 Bash 测试：

```bash
bash tests/run-tests.sh
bash -n ubuntu-autoinstall/*.sh ubuntu-autoinstall/extras/scripts/*.sh scripts/*.sh
```

构建完成的 ISO 可用 `diagnose-iso.sh` 做结构检查：

```bash
sudo bash ubuntu-autoinstall/diagnose-iso.sh /path/to/output.iso
```

注意：自动安装会清空 `user-data` 中指定的目标磁盘，默认是 `/dev/sda`。
